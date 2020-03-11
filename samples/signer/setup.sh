#!/bin/bash

export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

environment () {

  # Set values that will be overwritten if env.sh exists
  echo "Setting up the environment..."
  export BINAUTHZ_PROJECT=$(gcloud config get-value project)
  export BINAUTHZ_PROJECTNUM=$(gcloud projects list --filter="${BINAUTHZ_PROJECT}" --format="value(PROJECT_NUMBER)")
  export BINAUTHZ_ZONE=us-central1a

  [[ -f "${DIR}/env.sh" ]] && echo "Importing environment from ${DIR}/env.sh..." && . ${DIR}/env.sh
  echo "Writing ${DIR}/env.sh..."
  cat > ${DIR}/env.sh << EOF
export BINAUTHZ_PROJECT=${BINAUTHZ_PROJECT}
export BINAUTHZ_PROJECTNUM=${BINAUTHZ_PROJECTNUM}
export BINAUTHZ_ZONE=${BINAUTHZ_ZONE}
EOF
}

binauthz_project_setup () {
  set +x; echo "Setting up project for Binary Authorization Sample..."
  set -x
  gcloud config set project ${BINAUTHZ_PROJECT}
  set +x; echo; set -x

  set +x; echo "Enabling apis..."; set -x
  gcloud services enable compute.googleapis.com
  gcloud services enable cloudbuild.googleapis.com
  gcloud services enable container.googleapis.com
  gcloud services enable containerregistry.googleapis.com
  gcloud services enable containeranalysis.googleapis.com
  gcloud services enable binaryauthorization.googleapis.com
  set +x; echo; set -x

  set +x; echo "Setting up service accounts and permissions.."; set -x
  gcloud projects add-iam-policy-binding ${BINAUTHZ_PROJECT} \
    --member serviceAccount:${BINAUTHZ_PROJECTNUM}@cloudbuild.gserviceaccount.com \
    --role roles/container.developer

  gcloud iam service-accounts create kritis-signer \
    --description "For creating attestations" \
    --display-name "kritis-signer"
  gcloud projects add-iam-policy-binding ${BINAUTHZ_PROJECT} \
    --member serviceAccount:kritis-signer@${BINAUTHZ_PROJECT}.iam.gserviceaccount.com \
    --role roles/containeranalysis.ServiceAgent
  gcloud projects add-iam-policy-binding ${BINAUTHZ_PROJECT} \
    --member serviceAccount:kritis-signer@${BINAUTHZ_PROJECT}.iam.gserviceaccount.com \
    --role roles/containeranalysis.notes.editor

  gcloud iam service-accounts keys create ${DIR}/kritis-service-account.json \
  --iam-account kritis-signer@${BINAUTHZ_PROJECT}.iam.gserviceaccount.com
  
  set +x; echo "Configuring docker to Container Registry authentication.."; set -x
  gcloud auth configure-docker
  set +x; echo

  set +x; echo "Creating target deployment cluster.."; set -x
  gcloud container clusters create \
    --enable-binauthz \
    --zone ${BINAUTHZ_ZONE} \
    binauthz-sample
  set +x; echo

  set +x; echo "Building custom python cloud builder.."; set -x
  docker build -t gcr.io/${BINAUTHZ_PROJECT}/python-builder:latest -f ./Dockerfile.python-builder .
  docker push gcr.io/${BINAUTHZ_PROJECT}/python-builder:latest
  set +x; echo


  set +x; echo "Building custom kritis signer cloud builder.."; set -x
  $(cd ../../; make signer-image)
  KRITIS_DIGEST=$(docker images gcr.io/${BINAUTHZ_PROJECT}/kritis-signer | grep gcr.io | head -1 | awk -e ' { print $2 } ')
  docker tag gcr.io/${BINAUTHZ_PROJECT}/kritis-signer:$KRITIS_DIGEST gcr.io/${BINAUTHZ_PROJECT}/kritis-signer:latest
  docker push gcr.io/${BINAUTHZ_PROJECT}/kritis-signer:latest
  set +x; echo

  set +x; echo "Generating keys.  When asked, please provide an empty passphrase.."; set -x
  GPG_OUTPUT="$(gpg --quick-generate-key --yes attestor@example.com)"
  KEY_FINGERPRINT="$(set +x; echo; set -x $GPG_OUTPUT | sed -n 's/.*\([A-Z0-9]\{40\}\).*/\1/p')"
  gpg --armor --export $KEY_FINGERPRINT > $DIR/gpg.pub
  gpg --armor --export-secret-keys $KEY_FINGERPRINT > $DIR/gpg.priv
  set +x; echo

  set +x; echo "Creating attestors.."; set -x
  ATTESTOR=kritis-attestor
  NOTE_ID=kritis-attestor-note
  cat > ${DIR}/note_payload.json << EOM
{
  "name": "projects/${PROJECT_ID}/notes/${NOTE_ID}",
  "attestation": {
    "hint": {
      "human_readable_name": "Kritis Signer Attestor Note"
    }
  }
}
EOM
  curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)"  \
    --data-binary @${DIR}/note_payload.json  \
    "https://containeranalysis.googleapis.com/v1/projects/${PROJECT_ID}/notes/?noteId=${NOTE_ID}"
  gcloud container binauthz attestors create ${ATTESTOR} \
    --attestation-authority-note=${NOTE_ID} \
    --attestation-authority-note-project=${PROJECT_ID}
  openssl ecparam -genkey -name prime256v1 -noout -out ec256.priv
  openssl ec -in ec256.priv -pubout -out ec256.pub
  gcloud --project="${PROJECT_ID}" \
    beta container binauthz attestors public-keys add \
    --attestor="${ATTESTOR}" \
    --pkix-public-key-file=ec256.pub \
    --pkix-public-key-algorithm=ecdsa-p256-sha256
  cat > ${DIR}/binauthz-policy.yaml << EOM
    admissionWhitelistPatterns:
    - namePattern: gcr.io/google_containers/*
    - namePattern: gcr.io/google-containers/*
    - namePattern: k8s.gcr.io/*
    - namePattern: gke.gcr.io/*
    - namePattern: gcr.io/stackdriver-agents/*
    defaultAdmissionRule:
      evaluationMode: REQUIRE_ATTESTATION
      enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
      requireAttestationsBy:
        - projects/${PROJECT_ID}/attestors/${ATTESTOR}
    name: projects/${PROJECT_ID}/policy
EOM
  gcloud container binauthz policy import ${DIR}/binauthzpolicy.yaml

  set +x; echo
  set +x
}

#Main
environment
binauthz_project_setup

