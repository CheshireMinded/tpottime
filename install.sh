#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Step 1: Update and Upgrade
echo "Updating and upgrading the system..."
apt update && apt upgrade -y

# Step 2: Install Docker
if ! command_exists docker; then
    echo "Installing Docker..."
    apt install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    add-apt-repository "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    systemctl enable docker && systemctl start docker
else
    echo "Docker already installed."
fi

# Add the current user to the Docker group for non-root Docker access
echo "Adding $USER to Docker group..."
usermod -aG docker $USER

# Step 3: Install OpenSSH Server if not installed
if ! command_exists sshd; then
    echo "OpenSSH Server not found. Installing OpenSSH Server..."
    apt install -y openssh-server
    systemctl enable ssh && systemctl start ssh
else
    echo "OpenSSH Server is already installed."
fi

# Step 4: Install T-Pot
if [ ! -d "/opt/tpotce" ]; then
    echo "Installing T-Pot..."
    git clone https://github.com/telekom-security/tpotce /opt/tpotce
    cd /opt/tpotce
    chmod +x installer.sh
    ./installer.sh <<EOF
y
h
mywebuser  # Change this to your preferred T-Pot web username
mypassword  # Change this to your preferred T-Pot web password
EOF
    echo "Rebooting the system to complete T-Pot installation..."
    reboot
else
    echo "T-Pot is already installed."
fi

# Step 5: Install Go for SwarmKit
if ! command_exists go; then
    echo "Installing Go..."
    apt install -y golang
    echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.profile
    source ~/.profile
fi

# Step 6: Install SwarmKit
if [ ! -d "/opt/swarmkit" ]; then
    echo "Cloning SwarmKit repository..."
    git clone https://github.com/moby/swarmkit.git /opt/swarmkit
    cd /opt/swarmkit
    make binaries
else
    echo "SwarmKit already cloned."
fi

# Step 7: Set up Swarm Manager Node
echo "Setting up Swarm Manager Node..."
/opt/swarmkit/bin/swarmd -d /tmp/node-1 --listen-control-api /tmp/node-1/swarm.sock --hostname node-1 &
sleep 5

# Step 8: Fetch Join Tokens
echo "Fetching Swarm Join Tokens..."
export SWARM_SOCKET=/tmp/node-1/swarm.sock
MANAGER_TOKEN=$(/opt/swarmkit/bin/swarmctl cluster inspect default | grep "Manager:" | awk '{print $3}')
WORKER_TOKEN=$(/opt/swarmkit/bin/swarmctl cluster inspect default | grep "Worker:" | awk '{print $3}')
echo "Manager Token: $MANAGER_TOKEN"
echo "Worker Token: $WORKER_TOKEN"

# Step 9: Display IP Address
echo "Detecting system IP address..."
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "System IP Address: $IP_ADDR"

# Step 10: Set up Worker Nodes
echo "Setting up Swarm Worker Nodes..."
/opt/swarmkit/bin/swarmd -d /tmp/node-2 --hostname node-2 --join-addr "$IP_ADDR:4242" --join-token "$WORKER_TOKEN" &
/opt/swarmkit/bin/swarmd -d /tmp/node-3 --hostname node-3 --join-addr "$IP_ADDR:4242" --join-token "$WORKER_TOKEN" &
sleep 5

# Optional: Promote a Worker to Manager
echo "Promoting node-3 to Manager..."
/opt/swarmkit/bin/swarmd -d /tmp/node-3 --hostname node-3 --join-addr "$IP_ADDR:4242" --join-token "$MANAGER_TOKEN" --listen-control-api /tmp/node-3/swarm.sock &

# Step 11: Deploy T-Pot Service via Swarm
echo "Deploying T-Pot Service on Swarm..."
/opt/swarmkit/bin/swarmctl service create --name tpot_service --image telekomsecurity/tpotce:latest --replicas 3

# Step 12: Install and Configure UFW
echo "Installing UFW and allowing necessary ports..."
apt install -y ufw
ufw allow OpenSSH

# Allow T-Pot ports (from T-Pot documentation)
tpot_ports=(64297 64295 64294 8080 9200 5601 64299)
for port in "${tpot_ports[@]}"; do
    ufw allow "$port"
done

# Enable UFW
ufw --force enable

# Step 13: Display Service Status
echo "Listing all Swarm services and nodes..."
/opt/swarmkit/bin/swarmctl service ls
/opt/swarmkit/bin/swarmctl node ls

echo "Setup complete! Access T-Pot at: https://$IP_ADDR:64297 (SSH via port 64295)"
echo "Please log out and log back in for Docker permissions to take effect."
