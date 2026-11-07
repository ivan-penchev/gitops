#!/usr/bin/python3
"""Atomic native TOML merge; passwords never become subprocess arguments."""
import base64
import ctypes
import ctypes.util
import hmac
import os
from pathlib import Path
import pwd
import re
import stat

from ansible.module_utils.basic import AnsibleModule

PHC = re.compile(r'^\$BALLOON-SHA256\$v=1\$s=1024,t=32\$([^$]+)\$([^$]+)$')


def balloon(password, salt):
    """Use the same Nettle primitive and parameters as FTL v6.8/password.c."""
    library = ctypes.util.find_library('nettle')
    if not library:
        raise ValueError('Required system libnettle is unavailable')
    nettle = ctypes.CDLL(library)
    nettle.nettle_balloon_itch.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
    nettle.nettle_balloon_itch.restype = ctypes.c_size_t
    nettle.nettle_balloon_sha256.argtypes = [ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t,
                                           ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                                           ctypes.c_void_p, ctypes.c_void_p]
    nettle.nettle_balloon_sha256.restype = None
    scratch = ctypes.create_string_buffer(nettle.nettle_balloon_itch(32, 1024))
    output = ctypes.create_string_buffer(32)
    nettle.nettle_balloon_sha256(1024, 32, len(password), password, len(salt), salt, scratch, output)
    return output.raw


def password_hash(password, previous):
    match = PHC.fullmatch(previous)
    if previous and not match:
        raise ValueError('Unrecognized native password hash')
    if match:
        salt = base64.b64decode(match[1], validate=True)
        old_hash = base64.b64decode(match[2], validate=True)
        if len(salt) != 16 or len(old_hash) != 32:
            raise ValueError('Invalid native password hash')
        if hmac.compare_digest(balloon(password, salt), old_hash):
            return previous
    salt = os.urandom(16)
    return '$BALLOON-SHA256$v=1$s=1024,t=32$' + base64.b64encode(salt).decode() + '$' + base64.b64encode(balloon(password, salt)).decode()


def read_password(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError('Password source must be a root-owned regular 0600 file')
        value = stream.read(4098)
    value = value.removesuffix(b'\n')
    if not value.strip() or len(value) > 4096 or b'\n' in value or b'\r' in value or b'\0' in value:
        raise ValueError('Password must be one nonempty line, at most 4096 bytes')
    value.decode('utf-8')
    return value


def merge(document, settings, password):
    changed = False
    for key, value in settings.items():
        table = document
        pieces = key.split('.')
        for section in pieces[:-1]:
            if section not in table:
                table[section] = {}
            table = table[section]
        if table.get(pieces[-1]) != value:
            table[pieces[-1]] = value
            changed = True
    if 'webserver' not in document:
        document['webserver'] = {}
    if 'api' not in document['webserver']:
        document['webserver']['api'] = {}
    api = document['webserver']['api']
    old_hash = api.get('pwhash', '')
    new_hash = password_hash(password, old_hash)
    if new_hash != old_hash:
        api['pwhash'] = new_hash
        changed = True
    # A persisted plaintext pseudo-property is never acceptable.
    if 'password' in api:
        del api['password']
        changed = True
    return changed


def atomic_write(path, content, uid, gid):
    stage = path.with_name('.pihole.toml.ansible-new')
    fd = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchown(stream.fileno(), uid, gid)
            os.fchmod(stream.fileno(), 0o640)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(stage, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        stage.unlink(missing_ok=True)


def main():
    module = AnsibleModule(argument_spec={
        'settings': {'type': 'dict', 'required': True},
        'password_file': {'type': 'path', 'required': True, 'no_log': True},
        'write_allowed': {'type': 'bool', 'default': False},
    }, supports_check_mode=True)
    try:
        import tomlkit
        path = Path('/etc/pihole/pihole.toml')
        if path.is_symlink():
            raise ValueError('Refusing symlinked native configuration')
        document = tomlkit.parse(path.read_text()) if path.exists() else tomlkit.document()
        changed = merge(document, module.params['settings'], read_password(module.params['password_file']))
        if changed and not module.check_mode:
            if not module.params['write_allowed']:
                raise ValueError('Configuration changed after comparison; a stopped service is required')
            user = pwd.getpwnam('pihole')
            atomic_write(path, tomlkit.dumps(document), user.pw_uid, user.pw_gid)
        module.exit_json(changed=changed)
    except Exception:
        # Parser/library errors can include secret-bearing input: never return them.
        module.fail_json(msg='Native private configuration failed; inspect local permissions/dependencies without disclosing contents')


if __name__ == '__main__':
    main()
