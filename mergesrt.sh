#!/bin/sh

DATA_DIR='/data'

sendToWebhook() {
    if [ -n "$WEBHOOK_URL" ] && [ -n "$WEBHOOK_TEMPLATE" ]; then
        data=$(eval "echo \"$WEBHOOK_TEMPLATE\"")
        curl -s -S -X POST -d "$data" -H "Content-Type: application/json" $WEBHOOK_URL
    fi
}

# MKVMERGE COMMANDS -------------------------------------------------------------------
merge() {
    output=$1
    input=$2
    import=$3
    ext=$4
    type=$5
    lang=$6

    case $ext in
                srt)
                    if [ "$type" == "sdh" ] || [ "$type" == "hi" ] || [ "$type" == "cc" ]; then
                        mkvmerge -o "$output" "$input" --language 0:$lang --track-name 0:$type --hearing-impaired-flag 0:true "$import"
                    elif [ "$type" == "forced" ]; then
                        mkvmerge -o "$output" "$input" --language 0:$lang --track-name 0:$type --forced-display-flag 0:true "$import"
                    else
                        mkvmerge -o "$output" "$input" --language 0:$lang --track-name 0:$lang "$import"
                    fi
                    return 
                    ;;
                idx)
                    mkvmerge -o "$output" "$input" "$import"
                    return
                    ;;
            esac
}

# PROCESS FILE INFORMATION HERE ---------------------------------------------------------
process() {
    IMPORT_FILE=$1
    echo "--------------------------- START PROCESS --------------------------"
    echo -e "\e[1;34mImported file: $IMPORT_FILE\e[m"
    # PARSE FILE COMPONENTS ------------------------------------------------------------
    EXT=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f1 | rev)
    echo -e "\e[1;34mExtension: $EXT\e[m"
  
    if [ "$EXT" == "srt" ]; then
        # Check file endings against a ISO 639-1 and ISO 639-2 list to determine if valid LANG
        F2="$(curl -s -L https://datahub.io/core/language-codes/r/1.csv | grep -ow $(echo "$IMPORT_FILE" | rev | cut -d'.' -f2 | rev))"
        F3="$(curl -s -L https://datahub.io/core/language-codes/r/1.csv | grep -ow $(echo "$IMPORT_FILE" | rev | cut -d'.' -f3 | rev))"
        
        # Check Language
        if [ -n "$F2" ] && [ -z "$F3" ]; then # Check if first valid after .EXT
            LANG=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f2 | rev)
            TYPE=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f3 | rev)
        elif [ -n "$F3" ] && [ -z "$F2" ]; then # Check if second valid after .EXT
            LANG=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f3 | rev)
            TYPE=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f2 | rev)
        elif [ -n "$F2" ] && [ -n "$F3" ]; then # Check if both valid (edge case of using hi)
            # Use hi as TYPE (should help prevent Hindu 2 lang code issues)
            if [ $(echo "$IMPORT_FILE" | rev | cut -d'.' -f2 | rev) == 'hi' ]; then
                LANG=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f3 | rev)
                TYPE=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f2 | rev)
            else
                LANG=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f2 | rev)
                TYPE=$(echo "$IMPORT_FILE" | rev | cut -d'.' -f3 | rev)
            fi
        else
            echo -e "\e[0;31mCould not determine file language, skipping\e[m"
            return
        fi
        echo -e "\e[1;34mSubtitle language: $LANG\e[m"
        
        #Check TYPE
        if [ "$TYPE" == 'sdh' ] || [ "$TYPE" == 'forced' ] || [ "$TYPE" == 'hi' ] || [ "$TYPE" == 'cc' ]; then
            echo -e "\e[1;34mSubtitle type: $TYPE\e[m"
            # Determine if LANG.TYPE or TYPE.LANG format
            if [ -n "$F2" ]; then
                FILE_NAME=$(echo "$IMPORT_FILE" | sed 's|\.'"$TYPE"'\.'"$LANG"'\.'"$EXT"'||')
            else
                FILE_NAME=$(echo "$IMPORT_FILE" | sed 's|\.'"$LANG"'\.'"$TYPE"'\.'"$EXT"'||')
            fi
        else 
            TYPE=""
            FILE_NAME=$(echo "$IMPORT_FILE" | sed 's|\.'"$LANG"'\.'"$EXT"'||')
        fi
    else
        FILE_NAME=$(echo "$IMPORT_FILE" | sed 's|\.'"$EXT"'||')
    fi
    echo -e "\e[1;34mFile name: $FILE_NAME\e[m"
    
    VIDEO_FILE=$FILE_NAME'.mkv'
    # CHECK IF VIDEO EXISTS -------------------------------------------------------------
    if [ ! -f "$VIDEO_FILE" ]; then
        VIDEO_FILE=$FILE_NAME'.mp4'
    fi
    if [ ! -f "$VIDEO_FILE" ]; then
        echo -e "\e[0;31mFile $VIDEO_FILE does not exist, skipping\e[m"
        return
    fi
    echo -e "\e[1;32mSTARTING MERGE\e[m"
    MERGE_FILE=$FILE_NAME'.merge'
    FILE=$(echo "$FILE_NAME" | rev | cut -d'/' -f1 | rev)
    
    merge "$MERGE_FILE" "$VIDEO_FILE" "$IMPORT_FILE" "$EXT" "$TYPE" "$LANG"
    # When doing large batches sometimes the merge does not seem to work correctly.
    # this is used to keep running the merge untill the file has detected a subtitle.
    while !(mkvmerge --identify "$MERGE_FILE" | grep -c 'subtitle') do
        echo -e "\e[0;31mSubtitle is missing from merge file.  Rerunning merge\e[m"
        rm "$MERGE_FILE"
        merge "$MERGE_FILE" "$VIDEO_FILE" "$IMPORT_FILE" "$EXT" "$TYPE" "$LANG"
    done
    RESULT=$?
    # CLEAN UP  --------------------------------------------------------------------------
    if [ "$RESULT" -eq "0" ] || [ "$RESULT" -eq "1" ]; then
        RESULT=$([ "$RESULT" -eq "0" ] && echo -e "\e[1;32mMERGE SUCCEEDED\e[m" || echo -e "\e[1;33mMERGE COMPLETED WITH WARNINGS\e[m")
        echo "$RESULT"
        echo "Delete $IMPORT_FILE"
        rm "$IMPORT_FILE"
        rm "$FILE_NAME.sub"
        echo "Delete $VIDEO_FILE"
        rm "$VIDEO_FILE"
        echo "Rename $MERGE_FILE to $FILE_NAME.mkv"
        mv "$MERGE_FILE" "$FILE_NAME.mkv"
        # rm "$MERGE_FILE"
        echo "---------------------------- END PROCESS ---------------------------"
    else
        echo -e "\e[0;31mMERGE FAILED\e[m"
    fi

    sendToWebhook
}

# LOOK FOR FILES ON STARTUP -------------------------------------------------------------
find "$DATA_DIR" -type f -name "*.???*.??.srt" -o -name "*.???*.???.srt" -o -name "*.idx" |
    while read file; do
        process "$file"
    done
    
# MONITOR FOR NEW FILES IN DIR ----------------------------------------------------------
inotifywait -m -r $DATA_DIR -e create -e moved_to --include '.*\.([a-z]{2,3}\.srt|idx)$' --format '%w%f' |
    while read file; do
        echo "The file '$file' was created/moved"
        process "$file"
    done
