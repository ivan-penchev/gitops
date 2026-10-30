# Non-secret settings for this cluster, tracked so plans match on any machine.
# Secrets come from secrets.sops.env via terraform/tf.sh.

# Set after the one-time pg-01 host step (zfs create + bind mount). See the
# header of postgres.tf. Keep false on a fresh rebuild until that is done.
postgres_data_mounted = true
