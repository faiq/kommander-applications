#!/usr/bin/env bash
set -euxo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
LATEST_FLUX_VERSION="$(gh api -X GET "repos/fluxcd/flux2/releases" --jq '.[0].tag_name|sub("^v"; "")')"
readonly LATEST_FLUX_VERSION
CURRENT_FLUX_VERSION=$(find "${REPO_ROOT}/services/kommander-flux" -maxdepth 1 -regextype sed -regex '.*/[0-9]\+.[0-9]\+.[0-9]\+' -printf "%f\n" | sort -V | head -1)
readonly CURRENT_FLUX_VERSION
KOMMANDER_REPO_PATH="${REPO_ROOT}/kommander" # Override in CI to path of kommander repository.

function check_remote_branch() {
    if [[ -n $(git ls-remote --exit-code --heads git@github.com:mesosphere/"$1".git "$2") ]]; then
        echo "Flux update PR is already up!"
        exit 0
    fi
}

function update_flux() {
    readonly BRANCH_NAME="flux-update/${LATEST_FLUX_VERSION}"
    check_remote_branch "kommander-applications" "${BRANCH_NAME}"
    git checkout -b "${BRANCH_NAME}"

    asdf install flux2 "${LATEST_FLUX_VERSION}"
    asdf local flux2 "${LATEST_FLUX_VERSION}"

    mkdir -p "$REPO_ROOT/services/kommander-flux/$LATEST_FLUX_VERSION"
    pushd "$REPO_ROOT/services/kommander-flux/$LATEST_FLUX_VERSION"
    ls ..
    cp -a ../"$CURRENT_FLUX_VERSION"/* .
    rm -r ../"$CURRENT_FLUX_VERSION"
    rm templates/*
    flux install -n kommander-flux --export > templates/flux.yaml
    cp "$REPO_ROOT/hack/flux/flux-update-kustomization.yaml" templates/kustomization.yaml
    cp "$REPO_ROOT"/hack/flux/templates/* templates/
    kustomize build --output templates templates
    rm templates/flux.yaml templates/kustomization.yaml
    yq e -i ".metadata.name=\"kommander-flux-$LATEST_FLUX_VERSION-d2iq-defaults\"" defaults/cm.yaml
    pushd "templates"
    kustomize create --autodetect
    popd && popd

    # Update flux version in defaultApps whenever flux version is upgraded.
    sed -i "s/kommander-flux: \".*\"/kommander-flux: \"$LATEST_FLUX_VERSION\"/g" services/kommander/*/defaults/cm.yaml

    git add .tool-versions
    git add services

    if [[ -z "$(git config user.email 2>/dev/null || true)" ]]; then
        git config user.email "ci@mesosphere.com"
        git config user.name "mesosphere-teamcity"
    fi

    readonly COMMIT_MSG="feat: Upgrade flux to ${LATEST_FLUX_VERSION}"

    git commit -m "${COMMIT_MSG}"

    git push --set-upstream origin "${BRANCH_NAME}"

    git fetch origin main
    KOMMANDER_APPLICATIONS_PR=$(gh pr create --base main --fill --head "${BRANCH_NAME}" -t "${COMMIT_MSG}" -l ready-for-review -l ok-to-test -l slack-notify)
    readonly KOMMANDER_APPLICATIONS_PR
    echo "${KOMMANDER_APPLICATIONS_PR} is created"
}

function bump_kommander_repo_flux() {
    ls -latrh "${KOMMANDER_REPO_PATH}"
    if [ ! -d "${KOMMANDER_REPO_PATH}" ]; then
        echo "error: kommander repo path is invalid (set to \"${KOMMANDER_REPO_PATH}\"). skipping flux upgrade in kommander repo"
        return 0
    fi
    echo "kommander repo found at ${KOMMANDER_REPO_PATH} and attempting to create a flux bump PR"
    pushd "${KOMMANDER_REPO_PATH}"
    check_remote_branch "kommander" "${BRANCH_NAME}"
    git checkout -b "${BRANCH_NAME}"
    sed -i "s~KOMMANDER_APPLICATIONS_REF ?= main~KOMMANDER_APPLICATIONS_REF ?= ${BRANCH_NAME}~g" Makefile
    git add Makefile
    if [[ -z "$(git config user.email 2>/dev/null || true)" ]]; then
        git config user.email "ci@mesosphere.com"
        git config user.name "mesosphere-teamcity"
    fi
    git commit -m "${COMMIT_MSG}"
    git push --set-upstream origin "${BRANCH_NAME}"
    git fetch origin main
    gh pr create --base main --fill --head "${BRANCH_NAME}" -t "${COMMIT_MSG}" -l copy-flux-manifests -l ok-to-test -l ready-for-review -l stacked -b "Depends on ${KOMMANDER_APPLICATIONS_PR}"
    popd
}

if [ "${CURRENT_FLUX_VERSION}" == "${LATEST_FLUX_VERSION}" ]; then
  echo "Flux version is up to date - nothing to do"
  exit 0
fi

echo "Updating flux version from ${CURRENT_FLUX_VERSION} to ${LATEST_FLUX_VERSION}"

update_flux
bump_kommander_repo_flux
