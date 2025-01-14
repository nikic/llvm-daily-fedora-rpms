#!/bin/bash

set -x

set -eu

# Ensure Bash pipelines (e.g. cmd | othercmd) return a non-zero status if any of
# the commands fail, rather than returning the exit status of the last command
# in the pipeline.
set -o pipefail

proj=
yyyymmdd="$(date +%Y%m%d)"
snapshot_url_prefix=https://github.com/kwk/llvm-daily-fedora-rpms/releases/download/source-snapshot/

#############################################################################
#############################################################################

# see https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#grouping-log-lines
group() {
    echo "::group::$1" 1>&2
}
endgroup() {
    echo "::endgroup::"
}

usage() {
local script=$(basename $0)
cat <<EOF
Build LLVM snapshots...

Usage: ${script} --project <project> [--yyyymmdd <YYYYMMDD>]
EOF
}

# Takes an original spec file and prefixes snapshot information to it. Then it
# writes the generated spec file to a new location.
#
# @param orig_file Path to the original spec file.
# @param out_file Path to the spec file that's generated
new_snapshot_spec_file() {
    local orig_file=$1
    local out_file=$2

    cat <<EOF > ${out_file}
################################################################################
# BEGIN SNAPSHOT PREFIX
################################################################################

# FIXME: Disable running checks for the time being 
%global _without_check 1

%bcond_without snapshot_build

%if %{with snapshot_build}

# Check if we're building with copr
%if 0%{?copr_projectname:1}

# Remove the .copr prefix that is added here infront the build ID
# see https://pagure.io/copr/copr/blob/main/f/rpmbuild/mock.cfg.j2#_22-25
%global copr_build_id %{lua: print(string.sub(rpm.expand("%buildtag"), 6))}

%global copr_build_link https://copr.fedorainfracloud.org/coprs/build/%{copr_build_id}/
%endif

%global llvm_snapshot_yyyymmdd           ${yyyymmdd}
%global llvm_snapshot_version            ${llvm_version}
%global llvm_snapshot_version_major      ${llvm_version_major}
%global llvm_snapshot_version_minor      ${llvm_version_minor}
%global llvm_snapshot_version_patch      ${llvm_version_patch}
%global llvm_snapshot_git_revision       ${llvm_git_revision}
%global llvm_snapshot_git_revision_short ${llvm_git_revision_short}

%global llvm_snapshot_version_suffix     pre%{llvm_snapshot_yyyymmdd}.g%{llvm_snapshot_git_revision_short}

%global llvm_snapshot_source_prefix      ${snapshot_url_prefix}

# This prints a multiline string for the changelog entry
%{lua: function _llvm_snapshot_changelog_entry()
    assert(os.setlocale('C'))
    print(string.format("* %s LLVM snapshot - %s\n", os.date("%a %b %d %Y"), rpm.expand("%version")))
    print("- This is an automated snapshot build")
    -- TODO(kkleine): Switch to rpm.isdefined() once it is available on copr builders
    if rpm.expand("%copr_build_link") ~= "%copr_build_link" then
        print(string.format(" (%s)", rpm.expand("%copr_build_link")))
    end
    print("\n\n")
end}

%global llvm_snapshot_changelog_entry %{lua: _llvm_snapshot_changelog_entry()}

%endif

################################################################################
# END SNAPSHOT PREFIX
################################################################################

EOF
    
    cat ${orig_file} >> ${out_file}
}

new_compat_spec_file() {
    local orig_file=$1
    local out_file=$2

    cat <<EOF > ${out_file}
################################################################################
# BEGIN COMPAT PREFIX
################################################################################

%global _with_compat_build 1

################################################################################
# END COMPAT PREFIX
################################################################################

EOF
    
    cat ${orig_file} >> ${out_file}
}


# These will be set by create_spec_file
llvm_version=""
llvm_git_revision=""
llvm_git_revision_short=""
llvm_version_major=""
llvm_version_minor=""
llvm_version_patch=""

create_spec_file() {
    group "Get LLVM version"
    local url="${snapshot_url_prefix}llvm-release-${yyyymmdd}.txt"
    llvm_version=$(curl -sfL "$url")
    local ret=$?
    if [[ $ret -ne 0 ]]; then
        echo "ERROR: failed to get llvm version from $url"
        exit 1
    fi
    
    url="${snapshot_url_prefix}llvm-git-revision-${yyyymmdd}.txt"
    llvm_git_revision=$(curl -sfL "$url")
    llvm_git_revision_short=${llvm_git_revision:0:14}
    ret=$?
    if [[ $ret -ne 0 ]]; then
        echo "ERROR: failed to get llvm git revision from $url"
        exit 1
    fi
    llvm_version_major=$(echo $llvm_version | grep -ioP '^[0-9]+')
    llvm_version_minor=$(echo $llvm_version | grep -ioP '\.\K[0-9]+' | head -n1)
    llvm_version_patch=$(echo $llvm_version | grep -ioP '\.\K[0-9]+$')
     
    endgroup
    group "Reset project $proj"
    # Updates the LLVM projects with the latest version of the tracked branch.
    rm -rf $sources_dir

    git clone --quiet --origin upstream --branch upstream-snapshot https://src.fedoraproject.org/rpms/$proj.git ${sources_dir}
    # TODO(kkleine): Once upstream RPM repos can build compat packages properly, we can ditch this fork remote
    git -C ${sources_dir} remote add fork https://src.fedoraproject.org/forks/kkleine/rpms/$proj.git
    git -C ${sources_dir} fetch --quiet fork
    
    # Checkout OS-dependent branch from upstream if building compat package
    local branch="upstream/upstream-snapshot"
    case $orig_package_name in
        "compat-llvm-fedora-36" | "compat-clang-fedora-36")
            branch="fork/f36"
            ;;
        "compat-llvm-fedora-35" | "compat-clang-fedora-35")
            branch="fork/f35"
            ;;
        "compat-llvm-fedora-rawhide" | "compat-clang-fedora-rawhide")
            branch="fork/rawhide"
            ;;
    esac
    endgroup
    group "Reset to ${branch}"
    git -C $sources_dir reset --hard ${branch}
    unset branch

    endgroup
    group "Generate spec file in ${specs_dir}/$proj.spec"
    mv -v ${sources_dir}/$proj.spec ${sources_dir}/$proj.spec.old
    if [ "${opt_build_compat_packages}" != "" ]; then
        new_compat_spec_file "${sources_dir}/$proj.spec.old" ${specs_dir}/$proj.spec
    else
        new_snapshot_spec_file "${sources_dir}/$proj.spec.old" ${specs_dir}/$proj.spec
    fi
    endgroup
}

opt_build_compat_packages=""
orig_package_name=""
opt_workdir=$PWD
opt_build_srpm=""

while [ $# -gt 0 ]; do
    case $1 in
        --yyyymmdd )
            shift
            yyyymmdd="$1"
            ;;
        --project )
            shift
            proj="$1"
            orig_package_name="$proj"
            # NOTE: Implicitly enabling a compatibility build when the project's
            # name begins with "compat-". The project's name is manually
            # cleaned from the "compat-" prefix and the "-fedora-XX" suffix.
            case "$proj" in
                "compat-llvm-fedora-36" | "compat-llvm-fedora-35" | "compat-llvm-fedora-rawhide")
                    proj="llvm"
                    opt_build_compat_packages="1"
                    ;;
                "compat-clang-fedora-36" | "compat-clang-fedora-35" | "compat-clang-fedora-rawhide")
                    proj="clang"
                    opt_build_compat_packages="1"
                    ;;
            esac
            ;;
        --workdir )
            shift
            opt_workdir=$1
            ;;
        --build-srpm )
            opt_build_srpm=1
            ;;
        -h | -help | --help )
            usage
            exit 0
            ;;
        * )
            echo "unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ "${proj}" == "" ]]; then
    echo "Please specify which project to build (see --project <proj>)!"
    usage
    exit 1
fi


mkdir -pv ${opt_workdir}/{RPMS,SOURCES,SPECS,SRPMS,BUILD}
specs_dir=${opt_workdir}/SPECS
sources_dir=${opt_workdir}/SOURCES
spec_file=${specs_dir}/$proj.spec

create_spec_file

if [[ "$opt_build_srpm" == "1" ]]; then
    endgroup
    group "Downloading patches and source from listed in ${specs_dir}/$proj.spec"
    # Download files from the specfile into the current directory
    rpmdev-spectool \
        --debug \
        --get-files \
        --directory ${opt_workdir}/SOURCES \
        ${specs_dir}/$proj.spec
    echo "%_topdir ${opt_workdir}" >> ~/.rpmmacros
    endgroup
    group "Building SRPM from ${specs_dir}/$proj.spec"
    rpmbuild -vv -bs ${specs_dir}/$proj.spec
    endgroup
fi

exit 0
