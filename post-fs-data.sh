#!/system/bin/busybox sh

MODPATH="${0%/*}"
MODNAME="${MODPATH##*/}"

PACKAGES_XML="/data/system/packages.xml"
BACKUP_DIR="$MODPATH/backup"
MAX_BACKUP_FILES=4
CURRENT_TIMESTAMP=$(date +%s)

[ -z "$MODPATH" ] || ! echo "$MODPATH" | grep -q '/data/adb/modules/' &&
 MODPATH="$(dirname "$(readlink -f "$0")")"

[ -f "$MODPATH/util_functions.sh" ] && . "$MODPATH/util_functions.sh" || abort "! util_functions.sh not found!"

wait_for_data() {
 max_wait_time=30
 wait_interval=1
 i=0
 while [ "$i" -lt "$max_wait_time" ]; do
   if mount | grep -q "/data " && [ -f "$PACKAGES_XML" ]; then
     ui_print "/data is mounted and accessible."
     return 0
   fi
   ui_print "Waiting for /data to become accessible..."
   sleep "$wait_interval"
   i=$((i + wait_interval))
 done
 ui_print "Error: /data or $PACKAGES_XML did not become accessible within $max_wait_time seconds."
 return 1
}

process_xml() {
 xml_file="$1"
 base_name=$(basename "$xml_file")
 base_name_no_ext="${base_name%.*}"

 xml_temp="$MODPATH/temp_${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"
 xml_backup_file="$BACKUP_DIR/${base_name_no_ext}_$CURRENT_TIMESTAMP.xml"
 abxml_backup_file="$BACKUP_DIR/${base_name_no_ext}_$CURRENT_TIMESTAMP.abxml"

 ui_print "Starting to process XML file: $xml_file"

 ui_print "Creating backup of $xml_file..."
 backup_file_path=$(backup_file "$xml_file" "bak")
 backup_status=$?

 if [ $backup_status -eq 0 ]; then
   ui_print "Backup file path: $backup_file_path"
   abxml_original_backup_file="$backup_file_path"
 else
   ui_print "Error: backup_file failed."
   return 1
 fi

 file_type=$(file -b "$abxml_original_backup_file")
 is_text_xml=false
 if echo "$file_type" | grep -q -E "XML .* text|text"; then
   is_text_xml=true
 fi

 ui_print "abxml_original_backup_file is: Text XML"

 if boolval "$is_text_xml"; then
   ui_print "File is already text XML. Proceeding with modifications."
   cp "$abxml_original_backup_file" "$xml_temp"
 else
   ui_print "Converting ABX to text: $abxml_original_backup_file -> $xml_temp"
   if ! abx_to_text "$abxml_original_backup_file" "$xml_temp"; then
     ui_print "Error: abx_to_text failed!"
     cat "$abxml_original_backup_file" >"$MODPATH/abx_to_text_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.abx"
     rm "$xml_temp" 2>/dev/null
     return 1
   fi
 fi

 ui_print "Finding userId for com.android.vending in $xml_temp..."
 vending_uid=$(sed -n -E '/<package / {
   /name="com\.android\.vending"/ {
     s/.*userId="([^"]*)".*/\1/p
     q
   }
 }' "$xml_temp")

 if [ -z "$vending_uid" ]; then
   ui_print "Error: Could not find userId for com.android.vending in $xml_temp"
   rm "$xml_temp"
   return 1
 else
   ui_print "Found userId for com.android.vending: $vending_uid"
 fi

 ui_print "Starting to modify XML..."

 # Deduplicate installer/installInitiator/installerUid
 sed -i -E '
 :begin
   s/(([\r\n ]*installer="[^"]*")+)(.*)([\r\n ]*installer="[^"]*")+/\1\3/g
   t begin
 :begin2
   s/(([\r\n ]*installInitiator="[^"]*")+)(.*)([\r\n ]*installInitiator="[^"]*")+/\1\3/g
   t begin2
 :begin3
   s/(([\r\n ]*installerUid(-int)?="[^"]*")+)(.*)([\r\n ]*installerUid(-int)?="[^"]*")+/\1\3/g
   t begin3
 ' "$xml_temp"

 # Process only non-system <package> lines
 # We create a temp file, iterate line by line, skip system packages
 processed_temp="$MODPATH/temp_${base_name_no_ext}_processed_$CURRENT_TIMESTAMP.xml"
 while IFS= read -r line || [ -n "$line" ]; do
   case "$line" in
     *'<package '*)
       # Skip system packages
       if echo "$line" | grep -qE 'system="(true|1)"'; then
         printf '%s\n' "$line"
         continue
       fi

       # 1. installer
       if echo "$line" | grep -q 'installer='; then
         line=$(echo "$line" | sed -E 's/(installer=")[^"]*/\1com.android.vending/g')
       else
         line=$(echo "$line" | sed -E 's/(<package [^>]*)/ \1 installer="com.android.vending"/g')
       fi

       # 2. installInitiator
       if echo "$line" | grep -q 'installInitiator='; then
         line=$(echo "$line" | sed -E 's/(installInitiator=")[^"]*/\1com.android.vending/g')
       else
         line=$(echo "$line" | sed -E 's/(<package [^>]*)/ \1 installInitiator="com.android.vending"/g')
       fi

       # 3. installerUid
       if echo "$line" | grep -qE 'installerUid(-int)?='; then
         line=$(echo "$line" | sed -E 's/(installerUid(-int)?=")[^"]*/\1'"$vending_uid"'/g')
       else
         line=$(echo "$line" | sed -E 's/(<package [^>]*)/ \1 installerUid="'"$vending_uid"'"/g')
       fi

       # 4. Remove installOriginator
       line=$(echo "$line" | sed -E 's/[\r\n ]*installOriginator="[^"]*"//g')

       # 5. Remove isOrphaned if true or 1
       line=$(echo "$line" | sed -E 's/[\r\n ]*isOrphaned="(true|1)"//g')

       # 6. Remove installInitiatorUninstalled if true or 1
       line=$(echo "$line" | sed -E 's/[\r\n ]*installInitiatorUninstalled="(true|1)"//g')

       # 7. packageSource -> 2 (replace or add)
       if echo "$line" | grep -q 'packageSource='; then
         line=$(echo "$line" | sed -E 's/packageSource="[^2]"/packageSource="2"/g')
       else
         line=$(echo "$line" | sed -E 's/(<package [^>]*)/ \1 packageSource="2"/g')
       fi

       printf '%s\n' "$line"
       ;;
     *)
       printf '%s\n' "$line"
       ;;
   esac
 done < "$xml_temp" > "$processed_temp"

 mv "$processed_temp" "$xml_temp"

 ui_print "Rotating backups..."
 rotate_files "${base_name_no_ext}_*.xml" "$MAX_BACKUP_FILES"
 rotate_files "${base_name_no_ext}_*.abxml" "$MAX_BACKUP_FILES"

 if boolval "$is_text_xml"; then
   ui_print "Original file was text XML. Replacing with modified text XML."
   cp "$xml_temp" "$xml_backup_file"
   replacement_source="$xml_backup_file"
 else
   ui_print "Original file was ABX. Converting text to ABX before replacing."
   text_to_abx "$xml_temp" "$abxml_backup_file"
   replacement_source="$abxml_backup_file"
 fi

 ui_print "Replacing original file: $xml_file <- $replacement_source"
 if ! cp -f "$replacement_source" "$xml_file"; then
   ui_print "Error: Failed to copy modified file. Permissions issue?"
   rm "$xml_temp" 2>/dev/null
   return 1
 fi

 ui_print "Verifying replacement: $xml_file vs $replacement_source"
 if ! cmp -s "$xml_file" "$replacement_source"; then
   ui_print "Error: Verification failed after replacement!"
   diff -u "$xml_file" "$replacement_source" >"$MODPATH/diff_error_${base_name_no_ext}_$CURRENT_TIMESTAMP.diff"
   rm "$xml_temp" 2>/dev/null
   return 1
 fi

 ui_print "Cleaning up temporary files..."
 rm "$xml_temp" 2>/dev/null
 rm "$processed_temp" 2>/dev/null

 ui_print "Successfully processed XML file: $xml_file"
 return 0
}

if ! command_exists abx2xml || ! command_exists xml2abx; then
 ui_print "Error: abx2xml and xml2abx are required. Installing from addons..."
 for addon in "$MODPATH"/common/addon/*/install.sh; do
   if [ -f "$addon" ]; then
     addon_basedirname=$(basename "$(dirname "$addon")")
     ui_print "Running $addon_basedirname addon..."
     . "$addon"
     if [ $? -ne 0 ]; then
       ui_print "Error: Addon $addon_basedirname failed to install."
       exit 1
     fi
   fi
 done
 if ! command_exists abx2xml || ! command_exists xml2abx; then
   ui_print "Error: abx2xml and xml2abx are still missing after running addons."
   exit 1
 fi
fi

wait_for_data

ui_print "Processing $PACKAGES_XML..."
process_xml "$PACKAGES_XML"

ui_print "Restoring permissions and SELinux context..."
for file in "$PACKAGES_XML"; do
 chown system:system "$file"
 chmod 640 "$file"
 if command_exists restorecon; then
   restorecon "$file"
 fi
done

ui_print "----------------------------------------"
ui_print "Process completed successfully."
ui_print "Original and modified files backed up to: $BACKUP_DIR"
ui_print "It is recommended to reboot your device for changes to take effect."
ui_print "by @T3SL4"
ui_print "----------------------------------------"
