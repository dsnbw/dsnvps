#!/bin/bash
#curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version=$selected_value
#Lay noi dung file: /etc/dsnvps/.tmp/mariadbversionsetup.txt
if [ -f /etc/dsnvps/.tmp/mariadbversionsetup.txt ]; then
rm -rf /etc/dsnvps/.tmp/mariadbversionsetup.txt
fi
#latest_versions_server=$(curl -s https://dlm.mariadb.com/rest/releases/mariadb_server/)
#echo "$latest_versions_server" > /etc/dsnvps/.tmp/current_mariadb.txt
#file_path="/etc/dsnvps/.tmp/current_mariadb.txt"

# Lấy giá trị bắt đầu bằng 10.6.
#versionmariadbdaidat=$(grep -o '10\.6\.[0-9]\+' "$file_path" | head -n 1)
versionmariadbdaidat=$(cat /etc/dsnvps/menu/inc/mariadb.config.cnf/mariadbver.txt)
echo "$versionmariadbdaidat" > /etc/dsnvps/.tmp/mariadbversionsetup.txt
