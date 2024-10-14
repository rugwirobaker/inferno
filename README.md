# inferno
inferno is like docke but images run as firecracker microVMs
## Features
Currently we are targetting a very limited feature set:
1. **inferno run**: given an docker/oci image it should create a VM running with that image as the root filesystem.
2. **inferno stop**: stops a vm given it's unique id.
3. **inferno logs**: streams a vm's logs(the logs of whatever application i's running)

## Components
This project is composed of individual binaries that can each be independenty developed to a degree:
1. **inferno**: The main binary used to run the `inferno server` as a long running daemon but also inferno CLI with the commands we previously defined as features.
2. **kiln**: is actually all what this fuss is about. It's a custom firecracker jailer with a few more imporant features spiced in namely the logs and metrics.
3. **init**: to be able to test kiln we need something on the guest side to send back logs/metrics and that's where this mediocre init comes in. I wish it was written in rust.

## inferno commands:
Inferno currently has a few commands that mostly should be easy to understand

1. `inferno init`: generates a configuration file with some default values so we can run the server with `--config`
2. `inferno server`: runs the inferno server, it accepts a bunch of flags but it's better to configure by passsing the `--config` flag that accepts a file. Note that it requires root privileges to perfomr certain operations.
3. `inferno run`: already explaines in in the features section.
4. `inferno stop`: already explaines in in the features section.
5. `inferno logs`: already explaines in in the features section. Note that this is the most important command given the project's objectives though I haven't had the chance to work on it.
