source env.sh
DEBUG=*
# frey prepare --recipe envs/production --tools bin
frey plan --bail --recipe envs/production --tools bin
