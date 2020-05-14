#!/bin/bash
# Peter Long - March 2020
# Disclaimer / Warning
# Use this tool with precautions (review the config file created manually for a double-check) for your environment : it is NOT an official tool supported by Cloudian.
# Cloudian can NOT be involved for any bugs or misconfiguration due to this tool. So you are using it at your own risks and be aware of the restrictions.
#
# s3cmd/s4cmd
VERSION="v1.3.5"

## VARIABLES ##

S3CMD_ONLY=`which s3cmd`
S4CMD_ONLY=`which s4cmd`
DEBUG=no  #yes or no
CONFIG="s3cfg.conf"
OPT="--config="${CONFIG}
S3CMD=${S3CMD_ONLY}" "${OPT}
PROVIDER="s3://"
# Rubrik parameter for the MPU & PART
#MPU_SIZE=67108864
MPU_SIZE=16777216
NUMBER_PART=10000
# Change the Admin API password if needed
SCRIPTNAME=$0
HOWMANY=0
URL="https://raw.githubusercontent.com/pitdive/s3-bucket-migration/s4cmd/s3-bucket-migration.sh"

## CODE ##

# Function : Must acknowledge to continue with the current operation
Agree()
{
    read -r -t 60 -p "Do you want to continue (type : yes to continue, or anything else to abort) ? " answer
    case $answer in
        "yes")
            echo -e "OK, let's Go !"
        ;;
        *)
            echo -e "Well, aborting the script."
            for number in ${HOWMANY}
            do
                rm ${LOGFILE}.ls.${number}
            done
            exit 0
        ;;
    esac
}

# Purge a bucket by using Admin API (avoid tombstone)
Purge()
{
    echo -e "Purging the bucket : " $1 "\nNeed to connect to the cluster by using SSH and root access..."
    node=`cat ${CONFIG} | grep "puppet" | awk -F'=' '{print $2}' | sed 's/ //g' `
    password=`cat ${CONFIG} | grep "Syspassword" | awk -F'=' '{print $2}' | sed 's/ //g' `
    if [ -z ${node} ]
    then
        echo -e "--> Error, the node name is not available in the config file. Can't use the ADMIN API <--"
        exit 1
     fi
    local curl="curl --silent -X POST -ku sysadmin:"${password}
    curl=${curl}" 'https://localhost:19443/bucketops/purge?bucketName="$1" ' "
    ssh root@${node} ${curl}
    echo -e "\nWaiting a couple of seconds to apply changes ..."
    sleep 5
}

# Configure is needed to configure firstly everything for the migration
Configure()
{
    ${S3CMD} --configure --config ${CONFIG} --no-check-certificate --no-check-hostname --signature-v2
    if [ ! $? -eq 0 ]
       then echo -e "\n--> Error the config file CAN'T be set. Please, review the configuration. <--" && exit 1
    fi
    read -r -p "Please provide the @IP or name of the Cloudian puppet master : " PUPPET
    echo -e "Adding config into : " ${CONFIG}
    echo "puppet="$PUPPET >> ${CONFIG}
    ping -c 1 $PUPPET
    if [ ! $? -eq 0 ]
       then echo -e "\n--> Error the node seems not reachable. Please, check it and re-run the configuration. <--" && exit 1
    else
        if [ `ls ~/.ssh/*.pub | wc -l` -gt 0 ]
        then
            ssh-copy-id root@$PUPPET
        else
            ssh-keygen
            ssh-copy-id root@$PUPPET
        fi
    fi
    read -r -p "Please provide the Sysadmin password for Admin API connection : " PASSWORD
    echo "Syspassword="$PASSWORD >> ${CONFIG}
    echo -e "Configuration done.\n You can now continue for the automatic migration for multi-buckets with the command : \n \033[31m" ${SCRIPTNAME} "-c auto -b <bucketname>\033[0m"
}

# Update this script to the latest version
Update()
{
    echo -e "Trying to retrieve the latest version of the script with the default network access ..."
    if [ -f ${SCRIPTNAME} ]
    then
        mv ${SCRIPTNAME} ${SCRIPTNAME}.oldversion
    fi
    wget ${URL} -O ${SCRIPTNAME}
    if [ $? = 0 ]
    then
        echo -e "\n Keeping the oldest version with the name : "${SCRIPTNAME}.oldversion "\n Script upgraded to " `grep 'VERSION=' ${SCRIPTNAME}|head -1`
        chmod +x ${SCRIPTNAME}
        chmod 644 ${SCRIPTNAME}.oldversion
    else
        echo -e "\n--> Error during the download. Please check and retry ... <--"
        echo -e "No change made. Keeping existing version"
        rm ${SCRIPTNAME}
        mv ${SCRIPTNAME}.oldversion ${SCRIPTNAME}
        exit 1
    fi
}

# Synchronisation between the SRC bucket and the DST bucket (tempo)
# we have to do the job even for an empty bucket (there is no copy, just check + recreate the bucket)
Sync()
{
    echo -e "\033[31m--- Preparing to migrate the bucket : " ${BUCKETSRC} "--- \033[0m"
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
        echo -e "Migration of " $BUCKETSRC " is starting ... --->>>" > ${LOGFILE}
    fi
    echo -e "*** Preparation before SYNC  ***" >> ${LOGFILE}
    date >> ${LOGFILE}
    BUCKETTEMPO=${BUCKETSRC}"-tempo"
    echo -e "\nCreation of a temporary bucket to migrate firstly the data ... : " ${BUCKETTEMPO}
    ${S3CMD} mb ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    if [ $? -eq 0 ]
    then
        echo -e "Bucket " ${BUCKETTEMPO} " is now available. Continuing ..."
    else
        echo -e "\n--> Error during the creation of the bucket : "${BUCKETTEMPO}" \n Check the EndPoint. <--" && exit 1
    fi
    echo -e "--- Synchronization from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " : ---"
    echo -e "Checking for big files and MPU size compatibility ..."
    if [ ! -f ${LOGFILE}.ls.${BUCKETSRC} ]
    then
        ${S4CMD} ls ${PROVIDER}${BUCKETSRC} > ${LOGFILE}.ls.${BUCKETSRC}
        value=`cat ${LOGFILE}.ls.${BUCKETSRC} | awk '{print $3}' | sort | head -n 1`
        if [ -z "$value" ]
        then
            value=0
        fi
        let maxsize=${MPU_SIZE}*${NUMBER_PART}
        if [ "$value" -lt "$maxsize" ]
        then
            echo -e ${number}" --> Biggest object SIZE is : " $value " which is smaller than the max size MPU x PART: "${maxsize}
        else
            echo -e ${number}" --> Error, the biggest object SIZE is : " $value " which is BIGGER than the max size MPU x PART: "${maxsize}" <--"
            exit 1
        fi
    fi
    echo -e "\n*** Sync in progress  ***" >> ${LOGFILE} 2>&1
    ${S4CMD} dsync ${PROVIDER}${BUCKETSRC} ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1 &
    while [[ ! `ps -ef | grep ${S4CMD_ONLY} | grep ${BUCKETSRC}` = "" ]]
    do
        echo -ne "#"
        sleep 2
    done
    echo -e "\n*** Get the content of the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE}
    ${S4CMD} ls ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1

    echo -e "\n*** Calculating objects and size ***" >> ${LOGFILE}
    echo -e "Size and number of objects for the buckets " ${BUCKETSRC} >> ${LOGFILE}
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE}
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the buckets :"
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} > ${LOGFILE}.src && cat ${LOGFILE}.src
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} > ${LOGFILE}.tempo && cat ${LOGFILE}.tempo
    echo -e "\nSync is finished."
    echo -e "Next step --> reverse command.\033[31m" ${SCRIPTNAME} "-c reverse -b "${BUCKETSRC}"\033[0m"
}

# No more used or might be use for a manual step
Resync()
{
    echo -e "\n\033[31m--- RE-Synchronization from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " : --- \033[0m"
    #Agree
    echo -e "\n*** ReSync in progress from the bucket " ${BUCKETSRC} " to the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE}
    date >> ${LOGFILE}
    ${S4CMD} dsync ${PROVIDER}${BUCKETSRC} ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1 &
    while [[ ! `ps -ef | grep ${S4CMD_ONLY} | grep ${BUCKETSRC}` = "" ]]
    do
        echo -ne "#"
        sleep 2
    done
    echo -e "Resync done."

    echo -e "\n*** Calculating objects and size ***" >> ${LOGFILE}
    echo -e "Size and number of objects for the bucket " ${BUCKETSRC} >> ${LOGFILE}
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE}
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1

    echo -e "Re-Sync is finished."
    echo -e "Next step --> reverse command.\033[31m" ${SCRIPTNAME} "-c reverse -b "${BUCKETSRC}"\033[0m"
}

# Check the content of the two buckets
Check()
{
    echo -e "\n\033[31m--- Check the content of the buckets --- \033[0m"
    #Agree
    echo -e "MD5 calculations for " ${BUCKETSRC} " and " ${BUCKETTEMPO}
    echo -e "This might take long time and might use a lot of ressources ... depending on the structure of the buckets"
    echo -e "\n*** MD5 calculations ***" >> ${LOGFILE}
    date >> ${LOGFILE}
    echo -e "---------- BUCKET " ${BUCKETSRC} " ----------" >> ${LOGFILE}
    ${S3CMD} --recursive --list-md5 ls ${PROVIDER}${BUCKETSRC} > ${LOGFILE}.src.md5
    cat ${LOGFILE}.src.md5 >> ${LOGFILE}
    echo -e "---------- BUCKET " ${BUCKETTEMPO} " ----------" >> ${LOGFILE}
    ${S3CMD} --recursive --list-md5 ls ${PROVIDER}${BUCKETTEMPO} > ${LOGFILE}.tempo.md5
    cat ${LOGFILE}.tempo.md5 >> ${LOGFILE}
    echo -e "Done. All checksums are in the log file : " ${LOGFILE}
}

# Preparation of the buckets before the copy-back
Reverse()
{
    echo -e "\n\033[31m--- Reverse the operations from the bucket : " ${BUCKETTEMPO} " ---\033[0m"
    #Agree
    echo -e "\n*** Reverse in progress for the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE}
    date >> ${LOGFILE}
    echo -e "Purging the bucket : " ${BUCKETSRC} >> ${LOGFILE}
    Purge ${BUCKETSRC}
    ${S3CMD} --force rb ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "Creating a new bucket : " ${BUCKETSRC}
    ${S3CMD} mb ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "Delete is finished, if there is no error, please Go Forward ..."
    echo -e "Next step --> Copyback command. \033[31m" ${SCRIPTNAME} "-c copyback -b "${BUCKETSRC}"\033[0m"
}

# Copyback the object from the DST bucket to the SRC bucket
Copyback()
{
    echo -e "\n\033[31m--- Copy-back from the bucket : " ${BUCKETTEMPO} " to the bucket : " ${BUCKETSRC} " ---\033[0m"
    #Agree
    echo -e "\n*** Copy-Back in progress from the bucket " ${BUCKETTEMPO} " to the bucket " ${BUCKETSRC} " ***" >> ${LOGFILE}
    date >> ${LOGFILE}
    echo -e "Copy-back in progress ..."
    ${S4CMD} dsync ${PROVIDER}${BUCKETTEMPO} ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1 &
    while [[ ! `ps -ef | grep ${S4CMD_ONLY} | grep ${BUCKETSRC}` = "" ]]
    do
        echo -ne "#"
        sleep 2
    done
    echo -e "\n*** Calculating objects and size ***" >> ${LOGFILE}
    echo -e "Size and number of objects for the bucket " ${BUCKETSRC} >> ${LOGFILE}
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the bucket " ${BUCKETTEMPO} >> ${LOGFILE}
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "\nSize and number of objects for the buckets :" ${BUCKETSRC}
    ${S3CMD} du ${PROVIDER}${BUCKETSRC} > ${LOGFILE}.src && cat ${LOGFILE}.src
    ${S3CMD} du ${PROVIDER}${BUCKETTEMPO} > ${LOGFILE}.tempo && cat ${LOGFILE}.tempo
    echo -e "\nDone."
    echo -e "Next step --> Clean-up command. \033[31m" ${SCRIPTNAME} "-c clean -b "${BUCKETSRC}"\033[0m"
}

# Clean the DST bucket (tempo) and the logs not needed
Clean()
{
    echo -e "\n\033[31m--- Clean-up and deletion of non-necessary objects + bucket... ---\033[0m"
    #Agree
    echo -e "\n*** Cleanup in progress from the bucket " ${BUCKETTEMPO} " ***" >> ${LOGFILE}
    date >> ${LOGFILE}
    echo -e "Purging the bucket : " ${BUCKETTEMPO} >> ${LOGFILE}
    Purge ${BUCKETTEMPO}
    ${S3CMD} rb ${PROVIDER}${BUCKETTEMPO} >> ${LOGFILE} 2>&1
    echo -e "<<<--- *** Job done ***" >> ${LOGFILE}
    echo -e "Cleaning unnecessary log files ..."
    rm ${LOGFILE}.src ${LOGFILE}.tempo
    rm ${LOGFILE}.src.onlyhash ${LOGFILE}.tempo.onlyhash
    rm ${LOGFILE}.src.md5 ${LOGFILE}.tempo.md5
    rm ${LOGFILE}.ls.${BUCKETSRC}
    echo -e "Job done\n"
}

# Check if there is an error after a copy (MD5 calculations)
IsError()
{
    # First check : the #objects and size
    SRC=`cat ${LOGFILE}.src | awk -F' ' '{print $1 " " $2}'`
    TEMPO=`cat ${LOGFILE}.tempo | awk -F' ' '{print $1 " " $2}'`
    if [[ ${SRC} != ${TEMPO} ]]
    then
        echo -e "\n--> Error the bucket contents are different ! Please check and retry ... <--"
        exit 1
    fi
    # Second check : the MD5 hash
    if [ -f "${LOGFILE}.src.md5" ]
    then
        cat ${LOGFILE}.src.md5 | awk '{print $4}' > ${LOGFILE}.src.onlyhash
        cat ${LOGFILE}.tempo.md5 | awk '{print $4}' > ${LOGFILE}.tempo.onlyhash
        TEMPO=`diff ${LOGFILE}.src.onlyhash ${LOGFILE}.tempo.onlyhash`
        if [[ -z ${TEMPO} ]]
        then
            echo -e "\n Hashs are good, let's continue ..."
            echo -e "\n*** There is no error on #objects, bucket size and MD5 hashs ***" >> ${LOGFILE}
        else
            echo -e "\n--> Error the objects hashs are different ! Stopping now, please check and retry ... <--"
            echo -e "\n--> There IS somes errors on #objects, bucket size and MD5 hashs --> STOP the migration <--" >> ${LOGFILE}
            exit 1
        fi
    fi
}

# List how many buckets we have to migrate with the same prefix
HowMany()
{
    BUCKET=`echo ${BUCKETSRC} | sed "s/.$//"`
    # WE MUST USE S3CMD here ! S4CMD doesn't support the "root" as minimum parameter
    HOWMANY=`${S3CMD} ls ${PROVIDER} | awk -F${PROVIDER} '{print $2 " "}' | grep ${BUCKET}`
    echo -e "\n- We plan to migrate this : -\n"
    for number in ${HOWMANY}
    do
        echo -e " --> " ${number}
    done
    echo -e "\n- End of listing -"
}

# Due to Different MPU size for Rubrik, we must check the biggest object in the bucket and adjust the migration path
Check_MPUsize()
{
    check=0
    echo -e "\n- Checking MPU size for all the buckets ... -\n"
    for number in ${HOWMANY}
    do
        ${S4CMD} ls ${PROVIDER}${number} > ${LOGFILE}.ls.${number}
        value=`cat ${LOGFILE}.ls.${number} | awk '{print $3}' | sort | head -n 1`
        if [ -z "$value" ]
        then
            value=0
        fi
        let maxsize=${MPU_SIZE}*${NUMBER_PART}
        if [ "$value" -lt "$maxsize" ]
        then
            echo -e ${number}" --> Biggest object SIZE is : " $value " which is smaller than the max size MPU x PART: "${maxsize}
        else
            echo -e ${number}" --> Error, the biggest object SIZE is : " $value " which is BIGGER than the max size MPU x PART: "${maxsize}" <--"
            check=1
        fi
    done
    if [[ "$check" == 1 ]]
    then
        echo -e "You MUST migrate those buckets manually."
        exit 1
    else
        echo -e "...looks good \n"
    fi
}

Helpmessage()
{
    echo -e "The version of the tool is : " $VERSION"\n"
	echo -e "Use the format :" ${SCRIPTNAME} " -c <command> -b <bucketname>"
    echo -e "<command> could be : configure , update, auto, howmany [or a manual operation like : sync , resync , check , reverse , copyback , clean] \n"
}

# Basic tests
while getopts h:c:b: option
do 
  case "${option}"
  in
  c) OPERATION=${OPTARG};;
  b) BUCKETSRC=${OPTARG};;
  esac
done

if [[ ! -f "${S3CMD_ONLY}" ]] || [[ ! -f "${S4CMD_ONLY}" ]]
    then echo -e "\n--> Error. You must install the necessary tools s3cmd and s4cmd before using this script. <--" && exit 1
fi

if [ -z ${OPERATION} ]
	then
	    echo -e "\n--> Error in the command line. <--"
	    Helpmessage
	    exit 1
	elif [[ ! ${OPERATION} = "configure" ]] && [[ ! ${OPERATION} = "update" ]]
	    then
	        if [[ -z ${BUCKETSRC} ]]
	            then echo "--> Error in the command line. bucket name is empty / missing ... <--"
	            Helpmessage
	            exit 1
            fi
	        if [ ! -f ${CONFIG} ]
                then echo -e "--> Error the config file is not present, firstly please use : " ${SCRIPTNAME} " -c configure <--" && exit 1
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
    S4CMD=${S4CMD_ONLY}" --recursive --ignore-empty-source --secret-key="${SECRET_KEY}" --access-key="${ACCESS_KEY}" --endpoint-url="${ENDPOINT}" --multipart-split-size="${MPU_SIZE}" --max-singlepart-upload-size="${MPU_SIZE}" --max-singlepart-download-size="${MPU_SIZE}" --max-singlepart-copy-size="${MPU_SIZE}
fi

if [[ "${DEBUG}" == "yes" ]]
then
    S4CMD=${S4CMD}" --debug"
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
    "version")
        echo -e "The version of the tool is : " $VERSION"\n"
    ;;
    "update")
        Update
    ;;
    "auto")
        HowMany
        Check_MPUsize
        Agree
        for number in ${HOWMANY}
        do
            BUCKETSRC=${number}
            Sync
            Check
            IsError
            Reverse
            Copyback
            Check
            IsError
            Clean
        done
        echo -e "Nothing else to do."
        echo -e "\033[31mPlease resume the Archival Location matching the current migration \033[0m"
    ;;
    "howmany")
        HowMany
    ;;
    "sync")
        echo -e "\n--> Before the sync, please, FORCE, on Rubrik side, the Archive Location in 'Pause mode'"
        echo -e "--> Before the sync, please, ENABLE, on Cloudian side, the policy you have chosen as the default policy"
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
    "iserror")
        IsError
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
        echo -e "Nothing else to do."
        echo -e "\033[31mPlease resume the Archival Location matching the current migration \033[0m"
	;;
    *)
        echo -e "\n--> Error in the command line. Operation not recognized. Please check it and retry. <--\n"
        exit 2
    ;;
esac