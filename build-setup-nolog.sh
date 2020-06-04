#!/usr/bin/env bash

# FireSim initial setup script. Under FireSim-as-top this script will:
# 1) Initalize submodules (only the required ones, minimizing duplicates
# 2) Install RISC-V tools, including linux tools
# 3) Installs python requirements for firesim manager

# Under library mode, (2) is skipped.

# TODO: build FireSim linux distro here?

# exit script if any command fails
set -e
set -o pipefail

unamestr=$(uname)
RDIR=$(pwd)

FASTINSTALL=false
IS_LIBRARY=false
SKIP_TOOLCHAIN=false

function usage
{
    echo "usage: build-setup.sh [ fast | --fast] [--skip-toolchain] [--library]"
    echo "   fast: if set, pulls in a pre-compiled RISC-V toolchain for an EC2 manager instance"
    echo "   skip-toolchain: if set, skips RISC-V toolchain handling (cloning or building)."
    echo "                   The user must define $RISCV in their env to provide their own toolchain."
    echo "   library: if set, initializes submodules assuming FireSim is being used"
    echo "            as a library submodule. Implies --skip-toolchain "
}

if [ "$1" == "--help" -o "$1" == "-h" -o "$1" == "-H" ]; then
    usage
    exit 3
fi

while test $# -gt 0
do
   case "$1" in
        fast | --fast) # I don't want to break this api
            FASTINSTALL=true
            ;;
        --library)
            IS_LIBRARY=true;
            SKIP_TOOLCHAIN=true;
            ;;
        --skip-toolchain)
            SKIP_TOOLCHAIN=true;
            ;;
        -h | -H | --help)
            usage
            exit
            ;;
        --*) echo "ERROR: bad option $1"
            usage
            exit 1
            ;;
        *) echo "ERROR: bad argument $1"
            usage
            exit 2
            ;;
    esac
    shift
done

if [ "$SKIP_TOOLCHAIN" = true ]; then
    if [ -z "$RISCV" ]; then
        echo "ERROR: You must set the RISCV environment variable before running"
        echo "firesim/$0 if running under --library or --skip-toolchain."
        exit 4
    else
        echo "Using existing RISCV toolchain at $RISCV"
    fi
else
    RISCV=$(pwd)/riscv-tools-install
    export RISCV=$RISCV
    echo "Installing fresh RISCV toolchain to $RISCV"
fi

# Remove and backup the existing env.sh if it exists
# The existing of env.sh implies this script completely correctly
if [ -f env.sh ]; then
    mv -f env.sh env.sh.backup
fi

env_string=$(printf "# This file was generated by $0")

function env_append {
    env_string+=$(printf "\n$1")
}

env_append "export FIRESIM_ENV_SOURCED=1"

git config submodule.target-design/chipyard.update none
git submodule update --init --recursive #--jobs 8

if [ "$IS_LIBRARY" = false ]; then
    # This checks if firemarshal has already been configured by someone. If
    # not, we will provide our own config. This must be checked before calling
    # init-submodules-no-riscv-tools.sh because that will configure
    # firemarshal.
    marshal_cfg=$RDIR/target-design/chipyard/software/firemarshal/marshal-config.yaml
    if [ ! -f $marshal_cfg ]; then
      first_init=true
    else
      first_init=false
    fi

    git config --unset submodule.target-design/chipyard.update
    git submodule update --init target-design/chipyard
    cd $RDIR/target-design/chipyard
    ./scripts/init-submodules-no-riscv-tools.sh --no-firesim
    cd $RDIR

    # Configure firemarshal to know where our firesim installation is.
    # If this is a fresh init of chipyard, we can safely overwrite the marshal
    # config, otherwise we have to assume the user might have changed it
    if [ $first_init = true ]; then
      echo "firesim-dir: '../../../../'" > $marshal_cfg
    fi
    env_append "export FIRESIM_STANDALONE=1"
fi

# FireMarshal Setup
if [ "$IS_LIBRARY" = true ]; then
    target_chipyard_dir=$RDIR/../..

    # setup marshal symlink
    ln -sf ../../../software/firemarshal $RDIR/sw/firesim-software
else
    target_chipyard_dir=$RDIR/target-design/chipyard

    # setup marshal symlink
    ln -sf ../target-design/chipyard/software/firemarshal $RDIR/sw/firesim-software
fi

# RISC-V Toolchain Compilation
# When FireSim is being used as a library, the user is expected to build their
# own toolchain. For FireSim-as-top, call out to Chipyard's toolchain scripts.
if [ "$SKIP_TOOLCHAIN" != true ]; then
    # Restrict the devtoolset environment to a subshell
    #
    # The devtoolset wrapper around sudo does not correctly pass options
    # through, which causes an aws-fpga SDK setup script to fail:
    # platforms/f1/aws-fpga/sdk/userspace/install_fpga_mgmt_tools.sh
    (
        # Enable latest Developer Toolset for GNU make 4.x
        devtoolset=''
        for dir in /opt/rh/devtoolset-* ; do
            ! [ -x "${dir}/root/usr/bin/make" ] || devtoolset="${dir}"
        done
        if [ -n "${devtoolset}" ] ; then
            echo "Enabling ${devtoolset##*/}"
            . "${devtoolset}/enable"
        fi

        # Build the toolchain through chipyard (whether as top or as library)
        cd "$target_chipyard_dir"
        if [ "$FASTINSTALL" = "true" ] ; then
            ./scripts/build-toolchains.sh ec2fast
        else
            ./scripts/build-toolchains.sh
        fi
    )
    source "$target_chipyard_dir/env.sh"
    env_append "source $target_chipyard_dir/env.sh"
fi

cd $RDIR

# commands to run only on EC2
# see if the instance info page exists. if not, we are not on ec2.
# this is one of the few methods that works without sudo
if wget -T 1 -t 3 -O /dev/null http://169.254.169.254/; then
    cd "$RDIR/platforms/f1/aws-fpga/sdk/linux_kernel_drivers/xdma"
    make

    # Install firesim-software dependencies
    # We always setup the symlink correctly above, so use sw/firesim-software
    marshal_dir=$RDIR/sw/firesim-software
    cd $RDIR
    sudo pip3 install -r $marshal_dir/python-requirements.txt
    cat $marshal_dir/centos-requirements.txt | sudo xargs yum install -y
    wget https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git/snapshot/e2fsprogs-1.45.4.tar.gz
    tar xvzf e2fsprogs-1.45.4.tar.gz
    cd e2fsprogs-1.45.4/
    mkdir build && cd build
    ../configure
    make
    sudo make install
    cd ../..
    rm -rf e2fsprogs*

    # Setup for using qcow2 images
    cd $RDIR
    ./scripts/install-nbd-kmod.sh

    # Source {sdk,hdk}_setup.sh once on this machine to build aws libraries and
    # pull down some IP, so we don't have to waste time doing it each time on
    # worker instances
    AWSFPGA=$RDIR/platforms/f1/aws-fpga
    cd $AWSFPGA
    bash -c "source ./sdk_setup.sh"
    bash -c "source ./hdk_setup.sh"
fi

cd $RDIR
./scripts/build-libelf.sh
cd $RDIR
./scripts/build-libdwarf.sh

cd $RDIR
set +e
./gen-tags.sh
set -e

# Write out the generated env.sh indicating successful completion.
echo "$env_string" > env.sh

echo "Setup complete!"
echo "To generate simulator RTL and run sw-RTL simulation, source env.sh"
echo "To use the manager to deploy builds/simulations on EC2, source sourceme-f1-manager.sh to setup your environment."
echo "To run builds/simulations manually on this machine, source sourceme-f1-full.sh to setup your environment."
