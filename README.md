# Step 1:
Open proxmox shell and run:
curl -L -o new_vm.sh https://raw.githubusercontent.com/FootGod-bot/Proxmox-cloud-init-iso-script/refs/heads/main/new_vm.sh
Or this if you dont have curl:
wget -O new_vm.sh https://raw.githubusercontent.com/FootGod-bot/Proxmox-cloud-init-iso-script/refs/heads/main/new_vm.sh
# Step 2:
Create a new vm with no iso and no drive storage. These are configured later.
Find a cloud image for your OS. Example: https://cloud-images.ubuntu.com/jammy/current/ for Ubuntu Server.
Upload the .img file to proxmox like you would a ISO.
# Step 3:
Run the script with:
bash ./new_vm.sh
Select your .img by typing the number next to it, and type the id of the vm you just made.
It will then ask what storage to use. Chose what is best for you.
It will then ask how much storage you want the vm to have. Fill in with how much you need.
Next it will ask the username, password, ip, and cider. Leave blank for default. This can be changed later in the cloud-iit tab.
Then the script will be finished and you will need to update your vm before use. This may take a few hours.
