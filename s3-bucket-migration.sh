#!/bin/bash
# Peter Long - March 2020
# Disclaimer / Warning
# Use this tool with precautions (review the config file created manually for a double-check) for your environment : it is NOT an official tool supported by Cloudian.
# Cloudian can NOT be involved for any bugs or misconfiguration due to this tool. So you are using it at your own risks and be aware of the restrictions.
# v1.3b
# s3cmd/s4cmd

## VARIABLES ##

S3CMD_ONLY="/usr/bin/s3cmd"
S4CMD_ONLY="/usr/bin/s4cmd"
CONFIG="s3cfg.conf"
OPT="--config="${CONFIG}
#CMD=${S3CMD}" "${OPT}
S3CMD=${S3CMD_ONLY}" "${OPT}
PROVIDER="s3://"
# Change the Admin API password if needed
PASSWORD="public"
SCRIPTNAME=$0
HOWMANY=0

## CODE ##

# Function : Must acknowledge to continue with the current operation
Agree()
{
    read -r -t 30 -p "Do you want to continue (type : yes to continue,or anything else to abort) ? " answer
    case $answer in
        "yes")
            echo -e "OK, let's Go !"
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
    echo -e "\nWaiting a couple of seconds to apply changes ..."
    sleep 5
}

Configure()
{
       if [[ ! -f "${S3CMD_ONLY}" ]] || [[ ! -f "${S4CMD_ONLY}" ]]
            then echo -e "\n--> Error. You must install the necessary tools before using this script. <--" && exit 1
        fi
        ${S3CMD} --configure --config ${CONFIG} --no-check-certificate --no-check-hostname --signature-v2
        if [ ! $? -eq 0 ]
            then echo -e "\n--> Error the config file CAN'T be set. Please, review the configuration. <--" && exit 1
        fi
        read -r -p "Please provide the @IP or name of the Cloudian puppet master : " PUPPET
        echo -e "Adding config into : " ${CONFIG}
        echo "puppet="$PUPPET >> ${CONFIG}
        ping -c 2 $PUPPET
        if [ ! $? -eq 0 ]
            then echo -e "\n--> Error the node seems not reachable. Please, check it and re-run the configuration. <--" && exit 1
        fi
        echo -e "Configuration done.\n You can now proceed with the 'sync' command : \033[31m" ${SCRIPTNAME} "-c sync -b <bucketname>\033[0m"
}

Sync()
{
    echo -e "\033[31m--- Preparing to migrate the bucket : " ${BUCKETSRC} "--- \033[0m"
    echo -e "\n--> Before the sync, please, FORCE, on Rubrik side, the ArchiveLocation in 'Pause mode'"
    echo -e "--> Before the sync, please, ENABLE, on Cloudian side, the policy you have chosen as the default policy"
    #Agree
    echo -e "Checking the source bucket : " ${BUCKETSRC}
    ${S3CMD} info ${PROVIDER}${BUCKETSRC} | grep ${BUCKETSRC}
    if [ $? -eq 0 ]
    then
        echo -e "=> Bucket " ${BUCKETSRC} " is available and readable. Continuing ..."
    else
        echo -e "\n--> Error on the bucket name. Please check and retry ... <--" && exit 1
    fi
    if [ ! -f ${LOGFILE} ]
    then
        echo -e "\n\033[31mCreating a new logfile : " ${LOGFILE} " in the current directory.\033[0m"
        echo -e "Migration of " $BUCKETSRC " is starting ... --->>>" > ${LOGFILE} 2>&1
    fi
    echo -e "*** Preparation before SYNC  ***" >> ${LOGFILE} 2>&1
    date >> ${LOGFILE}
    BUCKETTEMPO=${BUCKETSRC}"-tempo"
    echo -e "\nCreation of a temporary bucket to migrate firstly the data ... : " ${BUCKETTEMPO}
    ${S3CMD} mb ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    ${S3CMD} ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    if [ $? -eq 0 ]
    then
        echo -e "Bucket " ${BUCKETTEMPO} " is now available. Continuing ..."
    else
        echo -e "\n--> Error during the creation of the bucket : "${BUCKETTEMPO}" \n Check the EndPoint. <--" && exit 1
    fi
    echo -e "--- Synchronization from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " : ---"
    echo -e "\n*** Sync in progress  ***" >> ${LOGFILE} 2>&1
    ${S4CMD} dsync ${PROVIDER}${BUCKETSRC} ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1 &
    while [[ ! `ps -ef | grep s4cmd | grep migration` = "" ]]
    do
        echo -ne "#"
        sleep 2
    done
    echo -e "\n*** Get the content of the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
    ${S3CMD} ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1

    echo -e "\n*** Calculating objects and size ***" >> ${LOGFILE} 2>&1
    echo -e "Size and number of objects for the buckets " ${BUCKETSRC} >> ${LOGFILE} 2>&1
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the buckets :"
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} > ${LOGFILE}.src && cat ${LOGFILE}.src
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} > ${LOGFILE}.tempo && cat ${LOGFILE}.tempo
    #echo -e "Checking the content of the bucket is possible by using the command :"
    #echo -e "\033[31m" $0 -c check $3 $4 "\033[0m\n"
    echo -e "\nSync is finished."
    echo -e "Please use reverse command.\033[31m" ${SCRIPTNAME} "-c reverse -b "${BUCKETSRC}"\033[0m"
}

Resync()
{
   echo -e "\n\033[31m--- RE-Synchronization from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " : --- \033[0m"
    #Agree
    echo -e "\n*** ReSync in progress from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
    date >> ${LOGFILE}
    ${S4CMD} dsync ${PROVIDER}${BUCKETSRC} ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "Resync done."
    #echo -e "\n\n Quick check if there are differences..."
    #${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETSRC}
    #${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETTEMPO}

    echo -e "\n*** Calculating objects and size ***" >> ${LOGFILE} 2>&1
    echo -e "Size and number of objects for the bucket " ${BUCKETSRC} >> ${LOGFILE} 2>&1
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1

    #echo -e "Checking the content of the bucket is possible by using the command :"
    #echo -e "\033[31m" $0 -c check $3 $4 "\033[0m\n"
    echo -e "Re-Sync is finished."
    echo -e "Please use reverse command.\033[31m" ${SCRIPTNAME} "-c reverse -b "${BUCKETSRC}"\033[0m"
}

Check()
{
    echo -e "\n\033[31m--- Check the content of the buckets --- \033[0m"
    #Agree
    echo -e "MD5 calculations for " ${BUCKETSRC} " and " ${BUCKETTEMPO}
    echo -e "This might take long time and might use a lot of ressources ... depending on the structure of the buckets"
    echo -e "\n*** MD5 calculations ***" >> ${LOGFILE} 2>&1
    date >> ${LOGFILE}
    echo -e "---------- BUCKET " ${BUCKETSRC} " ----------" >> ${LOGFILE} 2>&1
    ${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "---------- BUCKET " ${BUCKETTEMPO} " ----------" >> ${LOGFILE} 2>&1
    ${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "Done. All checksums are in the log file : " ${LOGFILE}
    echo -e "\nto continue with the process, you can adjust the protection policy on Cloudian - default policy will be selected"
    echo -e "Then, use reverse command.\033[31m" ${SCRIPTNAME} "-c reverse -b "${BUCKETSRC}"\033[0m"
}

Reverse()
{
    echo -e "\n\033[31m--- Reverse the operations from the bucket : " ${BUCKETTEMPO} " ---\033[0m"
    #Agree
    echo -e "\n*** Reverse in progress for the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
    date >> ${LOGFILE}
    echo -e "Purging the bucket : " ${BUCKETSRC} >> ${LOGFILE} 2>&1
    Purge ${BUCKETSRC}
    ${S3CMD} --force rb ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "Creating a new bucket : " ${BUCKETSRC}
    ${S3CMD} mb ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "Delete is finished, if there is no error, please Go Forward :-) ..."
    echo -e "Then, use the command : \033[31m" ${SCRIPTNAME} "-c copyback -b "${BUCKETSRC}"\033[0m"
}

Copyback()
{
    echo -e "\n\033[31m--- Copy-back from the bucket : " ${BUCKETTEMPO} " to the bucket : " ${BUCKETSRC} " ---\033[0m"
    #Agree
    echo -e "\n*** Copy-Back in progress from the bucket " ${BUCKETTEMPO} " to the bucket " ${BUCKETSRC} " ***" >> ${LOGFILE} 2>&1
    date >> ${LOGFILE}
    echo -e "Copy-back in progress ..."
    ${S4CMD} dsync ${PROVIDER}${BUCKETTEMPO} ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1 &
    while [[ ! `ps -ef | grep s4cmd | grep migration` = "" ]]
    do
        echo -ne "#"
        sleep 2
    done
    echo -e "\n*** Calculating objects and size ***" >> ${LOGFILE} 2>&1
    echo -e "Size and number of objects for the bucket " ${BUCKETSRC} >> ${LOGFILE} 2>&1
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the buckets :" ${BUCKETSRC}
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} > ${LOGFILE}.src && cat ${LOGFILE}.src
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} > ${LOGFILE}.tempo && cat ${LOGFILE}.tempo
    #echo -e "---------- BUCKET " ${BUCKETSRC} " ----------" >> ${LOGFILE} 2>&1
    #${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    #echo -e "---------- BUCKET " ${BUCKETTEMPO} " ----------" >> ${LOGFILE} 2>&1
    #${S3CMD} --list-md5 ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "\nDone."
    echo -e "Then, use the command : \033[31m" ${SCRIPTNAME} "-c clean -b "${BUCKETSRC}"\033[0m"
}

Clean()
{
    echo -e "\n\033[31m--- Cleanup and deletion of non-necessary objects + bucket... ---\033[0m"
    #Agree
    echo -e "\n*** Cleanup in progress from the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE} 2>&1
    date >> ${LOGFILE}
    echo -e "Purging the bucket : " ${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    Purge ${BUCKETTEMPO}
    ${S3CMD} rb ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "<<<--- *** Job done ***" >> ${LOGFILE} 2>&1
    rm ${LOGFILE}.src ${LOGFILE}.tempo
    echo -e "Job done. Nothing else to do."
    echo -e "\033[31mPlease resume the Archival Location matching the current migration \033[0m"
}

IsError()
{
    SRC=`cat ${LOGFILE}.src | awk -F' ' '{print $1 " " $2}'`
    TEMPO=`cat ${LOGFILE}.tempo | awk -F' ' '{print $1 " " $2}'`
    if [[ ${SRC} != ${TEMPO} ]]
    then
        echo -e "\n--> Error on the bucket name. Please check and retry ... <--"
        exit 1
    fi
}

HowMany()
{
    BUCKET=`echo ${BUCKETSRC} | sed "s/.$//"`
    HOWMANY=`${S3CMD} ls ${PROVIDER} | awk -F${PROVIDER} '{print $2}' | grep $BUCKET`
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
	    echo -e "Use the format :" ${SCRIPTNAME} " -c <command> -b <bucketname>"
        echo -e "<command> could be : configure , auto, howmany, sync , resync , check , reverse , copyback , clean\n"
	    exit 1
	elif [ ! ${OPERATION} = "configure" ]
	    then
	        if [ -z ${BUCKETSRC} ]
	            then echo "--> Error in the command line. bucket name is empty / missing ... <--" &&  exit 1
	        fi
	        if [ ! -f ${CONFIG} ]
                then echo -e "--> Error the config file is not present, please use : " ${SCRIPTNAME} " -c configure <--" && exit 1
            fi
fi

BUCKETTEMPO=${BUCKETSRC}"-tempo"
LOGFILE=${BUCKETSRC}".log"

# Retrieve info for s4cmd
if [ -f "${CONFIG}" ]
then
    ACCESS_KEY=`grep access_key ${CONFIG} | awk -F'=' '{print $2}' | sed 's/ //g'`
    SECRET_KEY=`grep secret_key ${CONFIG} | awk -F'=' '{print $2}' | sed 's/ //g'`
    ENDPOINT=`grep host_base ${CONFIG} | awk -F'=' '{print $2}' | sed 's/ //g'`
    ENDPOINT='http://'${ENDPOINT}
    S4CMD=${S4CMD_ONLY}" --recursive --secret-key="${SECRET_KEY}" --access-key="${ACCESS_KEY}" --endpoint-url="${ENDPOINT}" --multipart-split-size=16777216"
fi

# Disclaimer
echo -e "\n\033[31mDisclaimer / Warning"
echo -e "Use this tool with precautions (review the config file created manually for a double-check) for your environment : it is NOT an official tool supported by Cloudian."
echo -e "Cloudian can NOT be involved for any bugs or misconfiguration due to this tool. So you are using it at your own risks and be aware of the restrictions.\033[0m"

# Operations
case ${OPERATION} in
    "configure")
        Configure
    ;;
    "auto")
        Agree
        HowMany
        for NUMBER in ${HOWMANY}
        do
            BUCKETSRC=$NUMBER
            echo $BUCKETSRC
            Sync
            IsError
            Check
            Reverse
            Copyback
            IsError
            Check
            Clean
        done
    ;;
    "howmany")
        HowMany
        echo -e "\nWe will plan to migrate this :"
        echo -e ${HOWMANY}
    ;;
    "sync")
        Agree
        Sync
    ;;
	"resync")
	    Agree
        Resync
	;;
    "check")
        Check
    ;;
    "reverse")
        Agree
        Reverse
    ;;
	"copyback")
	    Agree
        Copyback
	;;
	"clean")
	    Agree
        Clean
	;;
    *)
        echo -e "\n--> Error in the command line. Operation not recognized. Please check it and retry again. <--\n"
        exit 2
    ;;
esac