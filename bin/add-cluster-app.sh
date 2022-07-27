#!/bin/bash
# $1 = location of gitops-workloads
# $2 = cluster name
# $3 = app name
# $4 = location of git-credentials template file
# $5 = private key file
# $6 = public key
# $7 = known hosts
# $8 = Sealed secrets public key .pem file

gitops_workloads=$(realpath "$1")
cluster_name=$2
app_name=$3
git_creds_file=$(realpath "$4")
private_key_file=$(realpath "$5")
public_key_file=$(realpath "$6")
known_hosts=$7
pem_file=$(realpath "$8")

mkdir -p $gitops_workloads/$cluster_name/$app_name
cp -R $gitops_workloads/template/app-template/* $gitops_workloads/$cluster_name/$app_name
grep -RiIl 'cluster-name' $gitops_workloads/$cluster_name/$app_name | xargs sed -i "s/cluster-name/$cluster_name/g"
grep -RiIl 'app-name' $gitops_workloads/$cluster_name/$app_name | xargs sed -i "s/app-name/$app_name/g"

# Prep the sealed secret

tmp_git_creds=$(mktemp /tmp/git-creds.yaml.XXXXXXXXX)
cp $git_creds_file $tmp_git_creds
APP_NAME=$app_name yq e '.metadata.name=strenv(APP_NAME)' -i $tmp_git_creds
KEY=$(cat $private_key_file | base64 -w 0) yq -i '.data.identity = strenv(KEY)' $tmp_git_creds
CERT=$(cat $public_key_file | base64 -w 0) yq -i '.data."identity.pub" = strenv(CERT)' $tmp_git_creds
HOSTS=$(echo $known_hosts | base64 -w 0) yq -i '.data.known_hosts = strenv(HOSTS)' $tmp_git_creds
kubeseal --cert $pem_file --format yaml <$tmp_git_creds >$gitops_workloads/$cluster_name/$app_name/git-secret.yaml
rm $tmp_git_creds

# Add to kustomization.yaml

yq -i e ".resources += [\"$app_name\"]" $gitops_workloads/$cluster_name/kustomization.yaml