#!/bin/bash

###############################################################
#
# delete_cluster_management.sh
#
###############################################################

connection_data()
{

cat <<EOF
{
    "password":"${argocd_pwd}",
    "username":"${argocd_user}"
}
EOF

}

###############################################################

error_data()
{

error_text="***pipeline_url*** : ${CI_PIPELINE_URL}

***job_url*** : ${CI_JOB_URL}

***instance*** : ${argocd_context}

***cluster*** : ${cluster_name}

***error_context*** :

${error}

***error_message*** :

$(jq -r '.message' response.txt 2>/dev/null)

"

cat <<EOF
{
    "text":"${error_text}"
}
EOF

}

###############################################################

get_projects_data()
{

curl -L \
-s \
-o response.txt \
-w "%{response_code}" \
-X GET \
"https://${argocd_uri}/api/v1/projects" \
-H "Accept: application/json" \
-H "Authorization: Bearer ${ARGOCD_TOKEN}"

}

###############################################################

get_project_data()
{

curl -L \
-s \
-o response.txt \
-w "%{response_code}" \
-X GET \
"https://${argocd_uri}/api/v1/projects/${project_name}" \
-H "Accept: application/json" \
-H "Authorization: Bearer ${ARGOCD_TOKEN}"

}

###############################################################

update_project_data()
{

response=$(
curl -L \
-s \
-o response.txt \
-w "%{response_code}" \
-X PUT \
"https://${argocd_uri}/api/v1/projects/${project_name}" \
-H "Accept: application/json" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer ${ARGOCD_TOKEN}" \
-d @"${TMP_DIR}/${project_name}.json"
)

if [[ "${response}" == "200" ]]
then

echo "INFO : AppProject ${project_name} updated."

else

error="Unable to update ${project_name}"

echo "${error}"

curl -L \
"${MATTERMOST_HOOK_URI}" \
-H "Content-Type: application/json" \
-d "$(error_data)"

return 1

fi

}

###############################################################

delete_cluster_data()
{

cluster_uri_encoded=$(jq -nr --arg x "${cluster_uri}" '$x|@uri')

response=$(
curl -L \
-s \
-o response.txt \
-w "%{response_code}" \
-X DELETE \
"https://${argocd_uri}/api/v1/clusters/${cluster_uri_encoded}" \
-H "Accept: application/json" \
-H "Authorization: Bearer ${ARGOCD_TOKEN}"
)

if [[ "${response}" == "200" || "${response}" == "204" ]]
then

echo "INFO : Cluster ${cluster_name} deleted."

else

error="Unable to delete ${cluster_name}"

echo "${error}"

curl -L \
"${MATTERMOST_HOOK_URI}" \
-H "Content-Type: application/json" \
-d "$(error_data)"

fi

}

###############################################################

mkdir -p backup
mkdir -p tmp

TMP_DIR=tmp

###############################################################

while IFS=";" read \
argocd_uri \
argocd_context \
argocd_user \
argocd_pwd
do

ARGOCD_TOKEN=$(
curl -L \
-s \
-X POST \
"https://${argocd_uri}/api/v1/session" \
-H "Content-Type: application/json" \
-d "$(connection_data)" \
| jq -r '.token'
)

if [[ -z "${ARGOCD_TOKEN}" || "${ARGOCD_TOKEN}" == "null" ]]
then

error="Unable to connect ${argocd_context}"

echo "${error}"

continue

fi

response=$(get_projects_data)

if [[ "${response}" != "200" ]]
then

error="Unable to retrieve AppProjects"

echo "${error}"

continue

fi

projects=$(jq -r '.items[].metadata.name' response.txt)

###############################################################
#
# Browse clusters
#
###############################################################

while IFS=";" read \
cluster_context \
cluster_name \
cluster_uri \
cluster_token
do

[[ -z "${cluster_name}" ]] && continue

if [[ "${cluster_context}" != "${argocd_context}" ]]
then
    continue
fi

echo
echo "###########################################################"
echo "#"
echo "# Cluster : ${cluster_name}"
echo "# Server  : ${cluster_uri}"
echo "#"
echo "###########################################################"

cluster_uri_encoded=$(jq -nr --arg x "${cluster_uri}" '$x|@uri')

response=$(
curl -L \
-s \
-o response.txt \
-w "%{response_code}" \
-X GET \
"https://${argocd_uri}/api/v1/clusters/${cluster_uri_encoded}" \
-H "Accept: application/json" \
-H "Authorization: Bearer ${ARGOCD_TOKEN}"
)

if [[ "${response}" != "200" ]]
then

echo "INFO : Cluster ${cluster_name} not found."

continue

fi

###############################################################
#
# Browse AppProjects
#
###############################################################

for project_name in ${projects}
do

echo
echo "INFO : Project ${project_name}"

response=$(get_project_data)

if [[ "${response}" != "200" ]]
then

echo "INFO : Unable to retrieve ${project_name}"

continue

fi

###############################################################
#
# JSON validation
#
###############################################################

jq empty response.txt >/dev/null 2>&1

if [[ "$?" != "0" ]]
then

echo "INFO : Invalid JSON"

continue

fi

project_exist=$(jq -r '.metadata.name // empty' response.txt)

if [[ -z "${project_exist}" ]]
then

echo "INFO : Invalid AppProject"

continue

fi

###############################################################
#
# Backup
#
###############################################################

mkdir -p backup/${argocd_context}

cp response.txt \
backup/${argocd_context}/${project_name}.json

###############################################################
#
# Destination exists
#
###############################################################

destination_found=$(
jq \
--arg SERVER "${cluster_uri}" \
'
[
.spec.destinations[]
| select(.server==$SERVER)
]
| length
' \
response.txt
)

if [[ "${destination_found}" == "0" ]]
then

echo "INFO : No destination found."

continue

fi

###############################################################
#
# Count destinations
#
###############################################################

before=$(jq '.spec.destinations|length' response.txt)

###############################################################
#
# Remove destination
#
###############################################################

jq \
--arg SERVER "${cluster_uri}" \
'
.spec.destinations |= map(
select(.server != $SERVER)
)
' \
response.txt \
> "${TMP_DIR}/${project_name}.json"

jq empty "${TMP_DIR}/${project_name}.json" >/dev/null 2>&1

if [[ "$?" != "0" ]]
then

echo "INFO : Generated JSON invalid."

rm -f "${TMP_DIR}/${project_name}.json"

continue

fi

after=$(jq '.spec.destinations|length' \
"${TMP_DIR}/${project_name}.json")

removed=$((before-after))

if [[ "${removed}" == "0" ]]
then

echo "INFO : Nothing to update."

rm -f "${TMP_DIR}/${project_name}.json"

continue

fi

echo
echo "INFO : Destinations before : ${before}"
echo "INFO : Destinations after  : ${after}"
echo "INFO : Removed             : ${removed}"

echo
echo "INFO : Removed destination(s)"

jq \
--arg SERVER "${cluster_uri}" \
-r '
.spec.destinations[]
| select(.server==$SERVER)
| " - namespace=\(.namespace) server=\(.server)"
' \
response.txt

###############################################################
#
# Dry Run
#
###############################################################

if [[ "${DRY_RUN}" == "true" ]]
then

echo
echo "INFO : DRY RUN"
echo "INFO : PUT ${project_name}"

rm -f "${TMP_DIR}/${project_name}.json"

continue

fi

###############################################################
#
# Update AppProject
#
###############################################################

update_project_data

rm -f "${TMP_DIR}/${project_name}.json"

done

###############################################################
#
# Final verification
#
###############################################################

reference_found="false"

for project_name in ${projects}
do

response=$(get_project_data)

if [[ "${response}" != "200" ]]
then

continue

fi

remaining=$(
jq \
--arg SERVER "${cluster_uri}" \
'
[
.spec.destinations[]
| select(.server==$SERVER)
]
| length
' \
response.txt
)

if [[ "${remaining}" != "0" ]]
then

reference_found="true"

echo
echo "INFO : Cluster still referenced by ${project_name}"

fi

done

###############################################################
#
# Delete cluster
#
###############################################################

if [[ "${reference_found}" == "true" ]]
then

echo
echo "INFO : Cluster ${cluster_name} still referenced."
echo "INFO : Delete skipped."

continue

fi

###############################################################
#
# Dry Run Delete
#
###############################################################

if [[ "${DRY_RUN}" == "true" ]]
then

echo
echo "INFO : DRY RUN"
echo "INFO : DELETE ${cluster_name}"

continue

fi

###############################################################
#
# Delete
#
###############################################################

delete_cluster_data

done < cluster_token.csv

###############################################################
#
# End Argocd instance
#
###############################################################

done < argocd_token.csv

###############################################################
#
# Cleanup
#
###############################################################

rm -rf tmp

###############################################################
#
# Summary
#
###############################################################

echo
echo "###############################################################"
echo "#"
echo "# DELETE CLUSTER MANAGEMENT FINISHED"
echo "#"
echo "###############################################################"

echo

if [[ "${DRY_RUN}" == "true" ]]
then

echo "Execution mode : DRY RUN"

echo
echo "No AppProject has been modified."
echo "No Cluster has been deleted."

else

echo "Execution mode : EXECUTION"

fi

echo
echo "Backup directory : backup/"
echo
echo "End."

exit 0
