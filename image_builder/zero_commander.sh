#!/bin/bash

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

. config.sh

function as_root()
{
    sudo $*
}


function as_user()
{
    sudo -u ${SUDO_USER} $*
}

function packages()
{
    log_zero "Installing local deb packages"

    log_zero "Updating apt"
    as_root apt-get update

    log_zero "Installing debs"
    as_root aptitude install -y \
      sshpass \
      build-essential \
      zlib1g-dev \
      libssl-dev \
      openssl \
      libreadline-dev \
      libyaml-dev \
      libyaml-ruby \
      libpq-dev \
      sqlite3 \
      libsqlite3-dev \
      libxslt-dev \
      libxml2-dev \
      ftp \
      genisoimage \
      kpartx \
      debootstrap \
      ipcalc \
      curl \
      wget \
      git-core

    log_zero "Done installing packages"
}

function prerequisites()
{
    log_zero "Installing prerequisites"
    as_user mkdir ~/prerequisites
    cd ~/prerequisites
    log_zero "Downloading ruby"
    as_user wget http://ftp.ruby-lang.org/pub/ruby/1.9/ruby-1.9.3-p392.tar.gz
    log_zero "Untaring and compiling ruby"
    as_user tar xzf ruby-1.9.3-p392.tar.gz
    cd ruby-1.9.3-p392/
    as_user ./configure
    as_user make
    as_root make install

    log_zero "Installing bundler"
    as_root gem install bundler

    log_zero "Installing kpartx version 0.9.4"
    cd ~/prerequisites
    as_user wget http://ubuntu.wikimedia.org/ubuntu//pool/main/m/multipath-tools/kpartx_0.4.9-3ubuntu5_amd64.deb
    as_root dpkg -i kpartx_0.4.9-3ubuntu5_amd64.deb

    log_zero "Done installing prerequisites"
}

function micro_bosh_stemcell()
{
    log_zero "Creating micro bosh stemcell"
    as_user mkdir ~/sources
    as_root rm -rf ~/sources/private-bosh
    as_root rm -rf /var/tmp/bosh/bosh_agent
    cd ~/sources
    log_zero "Cloning bosh git repo"
    as_user git clone ${git_bosh_repo}
    cd private-bosh
    as_user git reset --hard ${git_bosh_commit}

    as_user sed -i "s/git@github.com:/https:\/\/${git_user}:${git_password}@github.com\//g" .gitmodules
    log_zero "Downloading submodules for bosh repo"
    as_user git submodule update --init

    log_zero "Installing ruby gems"
    as_user bundle install
    log_zero "Doing rake all:install"
    as_root bundle exec rake all:install
    log_zero "Executing rake all:finalize_release_directory"
    as_root bundle exec rake all:finalize_release_directory
    log_zero "Executing rake stemcell:micro[vsphere]"
    as_root bundle exec rake stemcell:micro[vsphere]

    log_zero "Done creating micro bosh stemcell"
}

function deployer_update()
{
    log_zero "Updating deployer"
    as_user mkdir ~/sources
    as_user rm -rf ~/sources/private-uhuru-commander
    cd ~/sources

    log_zero "Cloning commander git repo"

    as_user git clone ${git_commander_repo}
    cd private-uhuru-commander
    as_user git reset --hard ${git_commander_commit}

    micro_bosh_tarball=`ls /var/tmp/bosh/bosh_agent*/work/work/*.tgz`
    log_zero "Copying micro bosh tarball from '${micro_bosh_tarball}'"
    as_root cp -f ${micro_bosh_tarball} ~/sources/private-uhuru-commander/image_builder/deployments/${micro_stemcell}

    cd ${original_dir}
    as_user cp -f config.sh ~/sources/private-uhuru-commander/image_builder/

    cd ~/sources/private-uhuru-commander/image_builder
    log_zero "Installing gems"
    as_user sed -i "s/ssh:\/\/git@github.com:/https:\/\/${git_user}:${git_password}@github.com\//g"
    as_user sed -i "s/git@github.com:/https:\/\/${git_user}:${git_password}@github.com\//g" Gemfile
    as_root bundle install

    log_zero "Done updating deployer"
}

function deployer_run()
{
    log_zero "Running deployer scripts"
    cd ~/sources/private-uhuru-commander/image_builder
    as_root bundle exec bash ./install.sh $*
    log_zero "Done running deployer scripts"
}


function create_ovf()
{
    [  which ovftool >/dev/null  ] &&
    {
        log_zero "Creating OVF file 'ucc-${version}.ofv'"
        micro_bosh_vm_name=`cat ~/sources/private-uhuru-commander/image_builder/deployments/bosh-deployments.yml | grep "vm_cid" | awk '{print $2}'`
        as_user mkdir ~/ovf
        cd ~/ovf
        vm="vi://vi://${vsphere_user}:${vsphere_password}@${vsphere_host}/${datacenter}/vm/${vm_folder}/${micro_bosh_vm_name}"
        as_user ovftool "ucc-${version}.ofv"
        log_zero "Done creating ovf file"
    } ||
    {
        log_zero '!!!WARNING!!! Skipping ovf generation because ovftool is not installed.'
    }
}

# delete deployment

[[ $1 == "help" ]] &&
{
log_zero "local_packages"
log_zero "local_prerequisites"
log_zero "local_create_micro"
log_zero "local_update_deployer"
log_zero "local_create_ovf"
log_zero "local_run_deployer"
log_deployer "    deployer_setup_vm"
log_deployer "    deployer_upload"
log_deployer "    deployer_start_build"
log_builder "        micro_packages"
log_builder "        micro_commander"
log_builder "        micro_stemcells"
log_builder "        micro_create_release"
log_builder "        micro_config_daemons"
log_builder "        micro_ttyjs"
log_builder "        micro_compile"
log_builder "        micro_cleanup"
log_builder "        micro_zero_free"
} ||
{
    original_dir=`pwd`
    as_root chmod 1777 /tmp
    param_present 'local_packages'          $* && packages
    param_present 'local_prerequisites'     $* && prerequisites
    param_present 'local_create_micro'      $* && micro_bosh_stemcell
    param_present 'local_update_deployer'   $* && deployer_update $*
    param_present 'local_run_deployer'      $* && deployer_run $*
    param_present 'local_create_ovf'        $* && create_ovf
}
