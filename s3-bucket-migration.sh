#!/bin/bash
# Peter Long - March 2020
# Disclaimer / Warning
# Use this tool with precautions (review the config file created manually for a double-check) for your environment : it is NOT an official tool supported by Cloudian.
# Cloudian can NOT be involved for any bugs or misconfiguration due to this tool. So you are using it at your own risks and be aware of the restrictions.
# v1.2b
# s3cmd/s4cmd

## VARIABLES ##

S3CMD="/usr/bin/s3cmd"
S4CMD="/usr/bin/s4cmd"
CONFIG="s3cfg.conf"
OPT="--config="${CONFIG}
#CMD=${S3CMD}" "${OPT}
S3CMD=${S3CMD}" "${OPT}
PROVIDER="s3://"
# Change the Admin API password if needed
PASSWORD="public"

## CODE ##

# Function : Must acknowledge to continue with the current operation
Agree()
{
    read -r -t 30 -p "Do you want to continue (type : yes to continue,or anything else to abort) ? " answer
    case $answer in
        "yes")
            echo "OK, let's Go !"
        ;;
        *)
            echo -e "Well, aborting the script."
            exit 0
        ;;
    esac
}

# Function : Purge a bucket by using Admin API (avoid tombstone)
Purge()
{
    echo -e "Purging the bucket : " $1 "\nNeed to connect to the cluster by using SSH and root access..."
    NODE=`cat ${CONFIG} | grep "puppet" | awk -F'=' '{print $2}' | sed 's/ //g' `
    if [ -z ${NODE} ]
    then
        echo -e "--> Error, the node name is not available in the config file. Can't use the ADMIN API <--"
        exit 1
     fi
    CURL="curl --silent -X POST -ku sysadmin:"${PASSWORD}
    CURL=${CURL}" 'https://localhost:19443/bucketops/purge?bucketName="$1" ' "
    ssh root@${NODE} ${CURL}
    echo -e "Waiting a couple of seconds to apply changes ..."
    sleep 5
}

# Basic tests
while getopts c:b: option
do 
  case "${option}"
  in
  c) OPERATION=${OPTARG};;
  b) BUCKETSRC=${OPTARG};;
  esac
done 

if [ -z ${OPERATION} ]
	then
	    echo -e "\n--> Error in the command line. <--"
	    echo -e "Use the format :" $0 -c "<command> -b <bucketname>"
        echo -e "<command> could be : configure , sync , resync , check , reverse , copyback , clean\n"
	    exit 1
	elif [ ! ${OPERATION} = "configure" ]
	    then
	        if [ -z ${BUCKETSRC} ]
	            then echo "--> Error in the command line. bucket name is empty / missing ... <--" &&  exit 1
	        fi
	        if [ ! -f ${CONFIG} ]
                then echo "--> Error the config file is not present, please use : " $0 " -c configure <--" && exit 1
            fi
fi

BUCKETTEMPO=${BUCKETSRC}"-tempo"
LOGFILE=${BUCKETSRC}".log"

# Retrieve info for s4cmd
ACCESS_KEY=`grep access_key ${CONFIG} | awk -F'=' '{print $2}'`
SECRET_KEY=`grep secret_key ${CONFIG} | awk -F'=' '{print $2}'`
ENDPOINT=`grep host_base ${CONFIG} | awk -F'=' '{print $2}'`
ENDPOINT='http://'${ENDPOINT}
S4CMD=${S4CMD}" --recursive --secret-key="${SECRET_KEY}" --access-key="${ACCESS_KEY}" --endpoint-url="${ENDPOINT}

# Disclaimer
echo -e "\n\033[31mDisclaimer / Warning"
echo -e "Use this tool with precautions (review the config file created manually for a double-check) for your environment : it is NOT an official tool supported by Cloudian."
echo -e "Cloudian can NOT be involved for any bugs or misconfiguration due to this tool. So you are using it at your own risks and be aware of the restrictions.\033[0m\n"

# Operations
case ${OPERATION} in
    "configure")
        if [ ! -f ${S3CMD} ] or [ ! -f ${S4CMD} ]
        then
            echo -e "\n--> Error. You must install the necessary tools before using this script. <--" && exit 1
        fi
        echo -e "\n--- Creating the configuration file with the AccessKey and SecretKey to manage the buckets ---"
        echo -e "[cloudian]\ntype = s3\nprovider = Other\nenv_auth = false\nacl = private" > $CONFIG
        if [ ! $? -eq 0 ]
            then echo -e "--> Error the config file CAN'T be set. Please, review the configuration. <--" && exit 1
        fi
        read -r -p "Please provide the AccessKey for the migration : " ACCESSKEY
        read -r -p "Please provide the SecretKey for the migration : " SECRETKEY
        read -r -p "Please provide the s3 EndPoint for the migration (example : http://s3-region.domainname) : " S3ENDPOINT
        echo -e "access_key_id = "$ACCESSKEY "\nsecret_access_key = "$SECRETKEY"\nendpoint = "$S3ENDPOINT >> $CONFIG
        ################### TO DO : PUPPET LOCATION @IP #####################################################################################""
        echo -e "Configuration done.\n You can now proceed with the 'sync' command : \033[31m" $0 "-c sync -b <bucketname>\033[0m"
    ;;
    "sync")
        echo -e "\033[31m--- Preparing to migrate the bucket : " ${BUCKETSRC} "--- \033[0m"
        Agree
        echo -e "Checking the source bucket : " ${BUCKETSRC}
        ${S3CMD} info ${PROVIDER}${BUCKETSRC}
        if [ $? -eq 0 ]
        then
            echo -e "\n=> Bucket " ${BUCKETSRC} " is available and readable. Continuing ..."
        else
            echo -e "\n--> Error on the bucket name. Please check and retry ... <--" && exit 1
        fi
        echo -e "\n\033[31mCreating a new logfile : " ${LOGFILE} " in the current directory.\033[0m"
        echo "*** Preparation before SYNC  ***" > ${LOGFILE} 2>&1

        BUCKETTEMPO=${BUCKETSRC}"-tempo"
        echo -e "Creation of a temporary bucket to migrate firstly the data ... : " ${BUCKETTEMPO}
        echo  ${S3CMD} mb ${PROVIDER}${BUCKETTEMPO}
        ${S3CMD} mb ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        ${S3CMD} ls ${PROVIDER}${BUCKETTEMPO}
        if [ $? -eq 0 ]
        then
            echo -e "\nBucket " ${BUCKETTEMPO} " is now available. Continuing ..."
        else
            echo -e "\n--> Error during the creation of the bucket : "${BUCKETTEMPO}" \n Check the EndPoint. <--" && exit 1
        fi
        echo -e "--- Synchronization from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " : ---"
        echo -e "*** Sync in progress  ***" > ${LOGFILE} 2>&1
        ${S4CMD} dsync ${PROVIDER}${BUCKETSRC} ${PROVIDER}${BUCKETTEMPO}
        echo -e "*** Get the content of the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
        ${S3CMD} ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1

        echo -e "\033[31mPlease, change the ArchiveLocation parameter and force it in 'Pause mode' \033[0m"
        echo -e "Then, use the command re-sync : \033[31m" $0 -c resync $3 $4 "\033[0m"
    ;;
	"resync")
        echo -e "\n\033[31m--- RE-Synchronization from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " : --- \033[0m"
        Agree
        echo "*** ReSync in progress from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
        ${S4CMD} dsync ${PROVIDER}${BUCKETSRC} ${PROVIDER}${BUCKETTEMPO}
        echo -e "Resync done."
        #echo -e "\n\n Quick check if there are differences..."
        #${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETSRC}
        #${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETTEMPO}

        echo -e "*** Calculating objects and size ***" >> ${LOGFILE} 2>&1
        echo -e "\nSize and number of objects for the bucket " ${BUCKETSRC} >> ${LOGFILE} 2>&1
        ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
        echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1

        echo -e "Checking the content of the bucket is possible by using the command :"
        echo -e "\033[31m" $0 -c check $3 $4 "\033[0m\n"

        echo -e "Re-Sync is finished. You can adjust the protection policy on Cloudian - default policy will be selected"
        echo -e "Please use reverse command.\033[31m" $0 -c reverse $3 $4 "\033[0m"
	;;
    "check")
        echo -e "\n\033[31m--- Check the content of the buckets --- \033[0m"
        Agree
        echo -e "MD5 calculations for " ${BUCKETSRC} " and " ${BUCKETTEMPO}
        echo -e "This might take long time and might use a lot of ressources ... depending on the structure of the buckets"
        echo -e "---------- BUCKET " ${BUCKETSRC} " ----------" >> ${LOGFILE} 2>&1
        ${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
        echo -e "---------- BUCKET " ${BUCKETTEMPO} " ----------" >> ${LOGFILE} 2>&1
        ${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        echo -e "Done. All checksums are in the log file : " ${LOGFILE}

        echo -e "\n to continue with the process, you can adjust the protection policy on Cloudian - default policy will be selected"
        echo -e "Then, use reverse command.\033[31m" $0 -c reverse $3 $4 "\033[0m"
    ;;
    "reverse")
        echo -e "\n\033[31m--- Reverse the operations from the bucket : " ${BUCKETTEMPO} " ---\033[0m"
        Agree
        echo "*** Reverse in progress for the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
        echo -e "Purging the bucket : " ${BUCKETSRC} >> ${LOGFILE} 2>&1
        Purge ${BUCKETSRC}
        ${S3CMD} --force rb ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
        echo -e "Creating a new bucket : " ${BUCKETSRC}
        ${S3CMD} mb ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
        echo -e "Delete is finished, if there is no error, please Go Forward :-) ..."
        echo -e "Then, use the command : \033[31m" $0 -c copyback $3 $4 "\033[0m"
    ;;
	"copyback")
        echo -e "\n\033[31m--- Copy-back from the bucket : " ${BUCKETTEMPO} " to the bucket : " ${BUCKETSRC} " ---\033[0m"
        Agree
        echo "*** Copy-Back in progress from the bucket " ${BUCKETTEMPO} " to the bucket " ${BUCKETSRC} " ***" >> ${LOGFILE} 2>&1
        echo -e "Copy-back in progress ..."
        ${S4CMD} dsync ${PROVIDER}${BUCKETTEMPO} ${PROVIDER}${BUCKETSRC}
        #echo -e "\n\n Quick check if there are differences..."
        #${CMD} check --one-way ${PROVIDER}:${BUCKETSRC} ${PROVIDER}:${BUCKETTEMPO}
        echo -e "*** Calculating objects and size ***" >> ${LOGFILE} 2>&1
        echo -e "\nSize and number of objects for the bucket " ${BUCKETSRC} >> ${LOGFILE} 2>&1
        ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
        echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        echo -e "---------- BUCKET " ${BUCKETSRC} " ----------" >> ${LOGFILE} 2>&1
        ${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
        echo -e "---------- BUCKET " ${BUCKETTEMPO} " ----------" >> ${LOGFILE} 2>&1
        ${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        echo "Done."
        echo -e "Then, use the command : \033[31m" $0 -c clean $3 $4 "\033[0m"
	;;
	"clean") 
        echo -e "\n\033[31m--- Cleanup and deletion of non-necessary objects + bucket... ---\033[0m"
        Agree
        echo -e "*** Cleanup in progress from the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
        echo -e "Purging the bucket : " ${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        Purge ${BUCKETTEMPO}
        ${S3CMD} rb ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
        echo -e "*** Job done ***" >> ${LOGFILE} 2>&1
        echo -e "Job done. Nothing else to do."
        echo -e "\033[31m Please resume the ArchivalLocation matching the current migration \033[0m"
	;;
    *)
        echo -e "\n--> Error in the command line. Operation not recognized. Please check it and retry again. <--\n"
        exit 2
    ;;
esac