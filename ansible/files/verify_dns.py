"""Controller-origin DNS checks; only queries, no system resolver changes."""
import json
import sys

import dns.message
import dns.query
import dns.rcode
import dns.rdatatype


def check(server, external, local_name, local_address, blocked, query_functions=None):
    transports = query_functions or {'udp': dns.query.udp, 'tcp': dns.query.tcp}
    results = []
    for transport, query in transports.items():
        for purpose, hostname in [('external', external), ('local', local_name), ('blocked', blocked)]:
            if not hostname:
                continue
            reply = query(dns.message.make_query(hostname, 'A'), server, timeout=5)
            addresses = [str(item) for rrset in reply.answer if rrset.rdtype == dns.rdatatype.A for item in rrset]
            if purpose == 'blocked':
                valid = reply.rcode() == dns.rcode.NXDOMAIN or (reply.rcode() == dns.rcode.NOERROR and addresses == ['0.0.0.0'])
            elif purpose == 'local':
                valid = reply.rcode() == dns.rcode.NOERROR and addresses == [local_address]
            else:
                valid = reply.rcode() == dns.rcode.NOERROR and bool(addresses) and '0.0.0.0' not in addresses
            if not valid:
                raise RuntimeError(f'{transport} {purpose} DNS assertion failed for {hostname}')
            results.append(f'{transport}:{purpose}:ok')
    return results


if __name__ == '__main__':
    print(json.dumps(check(*sys.argv[1:])))
