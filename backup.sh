#!/bin/bash

# DESCRIPTION
# ------------------

#
# version 1.0-20211022
#
# This script exports all or just selected databases on Microsoft SQL Server,
# pack them into tarball archive and upload the archive to the SMB network
# location (Windows Share).
# Another functionalities are:
# - mounting the network location it the mountpoint is not persistent
# - cleaning up old files (how long backups should be stored - set the number
#   of days in variable)
# 
# It should not be hard to modify the script to suit your needs (upload just on
# hdd, upload to NFS share etc.
#
# >> CAVEATS: Usage of destination and temporary directory. Backup your server
# >> first.
#

# TERMS OF USE
# ------------------

# 2021, blaz@overssh.si
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the “Software”), to
# deal in the Software without restriction, including without limitation the 
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is 
# furnished to do so, subject to the following conditions:
# 
#  - The above copyright notice and this permission notice shall be included 
#    in all copies or substantial portions of the Software.
# 
#  - THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS
#    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
#    THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
#    DEALINGS IN THE SOFTWARE.

# CONFIGURATION
# ------------------

# local paths should NOT contain trailing slashes "/", otherwise the script
# will fail

	# MSSQL CONNECTION
	MSSQL_BACKUPUSER=sa				# mssql user with backup permissions
	MSSQL_BACKUPUSERPASS=pwd			# password
	MSSQL_DATABASES2BACKUP=("amdb") 		# databases for backup - ignored when MSSQL_BACKUPALL > 0
	MSSQL_DATABASES2IGNORE=("master", "tempdb") 	# ignored databases (only when MSSQL_BACKUPALL==1)
	MSSQL_BACKUPALL=1 				# backup everything if != 0 - check link above
	MSSQL_SYSTEM_USER=mssql 			# mssql process user

	# SMB CONNECTION
	SMB_USERNAME=shareusername			# smb share user with write permission
	SMB_PASSWORD=sharepassword			# smb user password
	SMB_SERVER=//server.domain/shareName		# server with exposed share
	SMB_MOUNTPOINT=/mnt/mountpointForShare		# local mountpoint
	SMB_IS_MOUNT_PERSISTENT=0			# if !=0: don't try to mount and unmount

	# BACKUP POLICY, ==0 RETAINS FOREVER
	EXPORT_RETENTION=7				# in days; if < 1, don't remove old backups

	# DIRECTORIES AND FILENAMES
	DIR_MSSQLEXPORTS=/opt/mssql-dumps		# temporary backup directory (raw backups)
							# ! don't put anything else in this directory !
							# ! you can wreck your server !
	DIR_SQLCMDBIN=/opt/mssql-tools/bin		# sqlcmd path - default set
	BACKUPSTRING_PREFIX=$(hostname)			# backup prefix - default is hostname

	# date and full path
	CURRENT_UNIX_TIMESTAMP=$(`echo date +%Y%m%d%H%M%S`)		# don't touch this line
	SMB_MOUNTPOINT_FULL=$SMB_MOUNTPOINT/$SMB_SERVER_SUB		# don't touch this line

# SCRIPT
# ------------------

	# CHECK IF NETWORK SHARE IS MOUNTED
	if grep -qs $SMB_MOUNTPOINT /proc/mounts; then
		# CONTINUE IF MOUNTED
		echo "Share already mounted, skipping."
	else
		# IF NOT MOUNTED
		# TRY TO MOUNT SMB SHARE, BUT ONLY IF NOT SET AS PERSISTENT
		if [[ $SMB_IS_MOUNT_PERSISTENT == 0 ]]; then
			echo "Share is not marked as persistent and has not been already mounted. Trying to establish the connection."
			mount -t cifs -o username=$SMB_USERNAME,password=$SMB_PASSWORD $SMB_SERVER $SMB_MOUNTPOINT
		else
			echo "Share is not mounted. Exiting because the share was marked as persistent."
			exit 1;
		fi
	fi

	# CHECK AGAIN IF SHARE IS MOUNTED
	if grep -qs $SMB_MOUNTPOINT /proc/mounts; then
		# SHARE MOUNTED, DO BACKUPS
		# Deleting old backups (set with retention option variable),
		# but only if retention > 0. Number in days.
		if [[ $EXPORT_RETENTION > 0 ]] ; then
			echo "Deleting all tarballs older than $EXPORT_RETENTION days."
			find $SMB_MOUNTPOINT/* -mtime +$EXPORT_RETENTION -exec rm *.tar.bz2 {} \;
		fi
		
		# create dump directory if it does not exist (using absolute path
		# from variable DIR_MSSQLEXPORTS)
		mkdir -p $DIR_MSSQLEXPORTS
		# set permissions for mssql user
		chown -R $MSSQL_SYSTEM_USER:$MSSQL_SYSTEM_USER $DIR_MSSQLEXPORTS
		
		# success or failura?
		if [ ! -d "$DIR_MSSQLEXPORTS" ]; then
			# can't write to temporary directory, fail
			echo "mkdir - check permissions"
			echo "Backup failed."
			exit 1;
		fi

		# cleanup temporary directory
		# ! be careful and don't put anything else inside this directory !
		# ! you can wreck your server !
		echo "Cleaning up temporary directory."
		find $DIR_MSSQLEXPORTS/ -mindepth 1 -delete

		# loop through databases or backup everything
		# remove headers and information about affected rows (tail/head)
		# ------
		# if MSSQL_BACKUPALL == 0 this part is ignored
		if [[ $MSSQL_BACKUPALL != 0 ]] ; then
			# include all databases
			# clear MSSQL_DATABASES2BACKUP just in case
			MSSQL_DATABASES2BACKUP=()
			# loop through and check if database should be included or not
			for CURRENTLINE in $(\
					$DIR_SQLCMDBIN/sqlcmd \
					-U $MSSQL_BACKUPUSER \
					-P$MSSQL_BACKUPUSERPASS \
					-Q "SELECT name FROM sys.databases" | tail -n +3 | head -n -1 \
			); do
				# don't backup databases that we wish to be ignored
				if [[ ! " ${MSSQL_DATABASES2IGNORE[*]} " =~ " ${CURRENTLINE} " ]]; then
					echo "Including database " $CURRENTLINE;
					# push to list
					MSSQL_DATABASES2BACKUP+=("$CURRENTLINE");
				else
					echo "Ignoring database  " $CURRENTLINE;
				fi
			done
		fi

		# create backups to temporary directory
		for DBNAME in "${MSSQL_DATABASES2BACKUP[@]}"; do
			echo "$DBNAME - creating backup"
			$DIR_SQLCMDBIN/sqlcmd \
				-U $MSSQL_BACKUPUSER \
				-P$MSSQL_BACKUPUSERPASS \
				-Q "BACKUP DATABASE [$DBNAME] TO DISK='$DIR_MSSQLEXPORTS/$DBNAME$CURRENT_UNIX_TIMESTAMP.mssqlbackup'"
			echo "BACKING UP " $DBNAME;
		done

		
		# clean destination (if tarball with the same name already exist)
		rm -f $SMB_MOUNTPOINT/$BACKUPSTRING_PREFIX\_$CURRENT_UNIX_TIMESTAMP.tar.bz2
		
		# squash all the exported backups into a tarball
		# on the newtork destination
		echo "Creating package $BACKUPSTRING_PREFIX into $SMB_MOUNTPOINT";
		tar --absolute-names -cjf \
			$SMB_MOUNTPOINT/$BACKUPSTRING_PREFIX\_$CURRENT_UNIX_TIMESTAMP.tar.bz2 \
			$DIR_MSSQLEXPORTS/*

		# clear output directory contents (comment out this line for debugging purposes)
		echo "Do some housekeeping."
		find $DIR_MSSQLEXPORTS/ -mindepth 1 -delete
		
		# disconnect nonpersistent share
		if [[ $SMB_IS_MOUNT_PERSISTENT == 0 ]]; then
			echo "Disconnecting from network share $SMB_MOUNTPOINT"
			# demand lazy unmount to avoid errors (busy file system)
			umount -l $SMB_MOUNTPOINT
		fi
		
		# finito
		echo "Reached end. Be sure to check your backups. This script does not detect sqlcmd, tar and IO errors."
		echo "Have a nice day!"
	fi
