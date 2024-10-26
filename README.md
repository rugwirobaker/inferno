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

## Running kiln + firecracker + init

This guide will walk you through setting up and running Kiln with its init program inside a Firecracker microVM, including building the necessary binaries, generating configurations, and preparing the initramfs.

### Prerequisites
* Linux machine with KVM support
* Docker (for extracting rootfs from containers)
* Golang installed (for compiling Kiln and other dependencies)
* GNU Make installed

### Steps
1. Make sure kvm is enabled and we have a copy of the firecracjer binary and the vmlinux kernel in the current directory. There is a script that:
    ```sh
    ./scripts/setup.sh
    ```
    This will first make sure kvm is enabled and then download the firecracker binary and the vmlinux kernel.

2. You'll need a rootfs for firecracker to boo with and lucky for you ./scripts/create_rootfs.sh has  you covered. It will create a rootfs for you from a docker image. You can run it like this:
    ```sh
    ./scripts/create_rootfs.sh <docker_image> <rootfs_dir>
    ```
    For example:
    ```sh
    ./scripts/create_rootfs.sh alpine:latest rootfs.ext4
    ```
    This will create a rootfs directory with the contents of the alpine:latest image.

3. Build Kiln and init
    ```sh
    make build
    ```
4. We need to move the init binary alongside its configuration file to an initramfs directory and packing it into a cpio archive. We can do this by running the following command:
```sh
    # generate example run.json
    cat > init/run.json <<EOF
    {
        "id": "test-vm",
        "process": {
            "cmd": "/bin/sh",
            "args": [
                "-c",
                "yes \"log message\" > /dev/stderr"
            ]
        },
        "env": {
            "PATH": "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
        },
        "log": {
            "format": "kernel",
            "timestamp": true,
            "debug": true
        },
        "vsock_stdout_port": 10000,
        "vsock_exit_port": 10001,
        "vsock_metrics_port": 10002,
        "vsock_signal_port": 10003
    }
    EOF
```

```sh
    # create initramfs directory 
    mkdir -p initramfs
    cp ./bin/init initramfs/inferno/init
    cp run.json initramfs/inferno/run.json
    cd initramfs
    find . | cpio -H newc -o> ../initrd.cpio
    cd ..
```
    This will create an initramfs.cpio file that we can use with firecracker.

5. Kiln requires a configuration file to run. You can generate an example configuration file by running:
```sh
./bin/kiln --init kiln.json
```

6. Generate firecracker configuration
```sh
cat > firecracker.json <<EOF
{
    "boot-source": {
        "kernel_image_path": "./vmlinux",
        initrd_path": "./initrd.cpio"
        "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
    },
    "drives": [
        {
            "drive_id": "rootfs",
            "path_on_host": "./rootfs.ext4",
            "is_root_device": true,
            "is_read_only": false
        }
        ],
        "machine-config": {
            "vcpu_count": 1,
            "mem_size_mib": 512
        },
        "logger": {
            "log_fifo": "log.fifo",
            "metrics_fifo": "metrics.fifo",
            "level": "Debug"
        },
        "vsock": {
            "vsock_device": "/tmp/vsock.sock"
        }
    }
EOF
```

Take note of the `initrd_path` and `path_on_host` fields in the configuration file. These should point to the initramfs.cpio and rootfs.ext4 files we created earlier.

7. Finally we can simply run kiln with the following command:
```sh
sudo ./bin/kiln
```
This will start a firecracker microVM with the rootfs we created earlier and the init program running inside it.

8. When you run a vm you might see a few errors about being unable to open a connection to vm_logs_socket. That's because the logs are to be sent to vector.dev via a socket. You can either ignore this or run the following command to create a socket:
```sh
sudo socat -d -d UNIX-LISTEN:./vm_logs.sock,reuseaddr,fork STDOUT
```
Or you can simply install vector.dev and run it with the following command:
```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.vector.dev | sh
```
Then you can run the following command to start vector.dev:
```sh
# there a vector config file at etc/vector.toml
vector --config etc/vector.toml
```

9. Cleaning up after each run should make your next run smoother since some of the files are created dynamically. You can do this by running the following command:
```sh
sudo make clean
```

10. Note that if you modify the init program you'll need to rebuild the initrd.cpio file.
