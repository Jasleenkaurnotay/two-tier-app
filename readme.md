# Two-Tier Application Deployment on AWS

An exercise demonstrating how to deploy a two-tier web application on AWS using a custom VPC, Auto Scaling Group (ASG), Application Load Balancer (ALB), and a managed RDS PostgreSQL database — with HTTPS termination at the load balancer.

---

## Architecture Overview

```
Internet
   │
   ▼
[ALB] (Public Subnets — 2 AZs)
   │  Port 80 / 443
   ▼
[ASG → EC2 App Servers] (Private Subnets — Port 8000)
   │
   ▼
[RDS PostgreSQL] (Isolated Private Subnets — Port 5432)
```

### VPC Subnet Layout

| Subnet Type | Purpose | Count |
|---|---|---|
| Public | ALB | 2 (one per AZ) |
| Private | EC2 app servers + NAT Gateway | 2 |
| Private (isolated) | RDS | 2 |

### Security Group Rules

| Resource | Inbound Rule |
|---|---|
| ALB | Port 80 and 443 from `0.0.0.0/0` |
| EC2 (ASG) | Port 8000 from ALB Security Group only |
| RDS | Port 5432 from EC2 Security Group only |

---

## Step-by-Step Setup

### Step 1: Create the RDS Database

1. Go to **RDS → Create database**
2. Engine: **PostgreSQL**, Template: **Free tier / Sandbox**, Single-AZ
3. Set a master username and a strong password (avoid special characters like `!` as they can break shell scripts)
4. Create a **custom DB subnet group** using the two isolated private subnets
5. Disable public access
6. Set an initial database name that matches what your application expects
7. Note the RDS endpoint once the instance is available — you'll need it in the user data script

---

### Step 2: Create the EC2 Launch Template

1. Go to **EC2 → Launch Templates → Create launch template**
2. Settings:
   - AMI: **Amazon Linux 2**
   - Instance type: `t2.micro`
   - Security group: the one allowing port 8000 from the ALB SG
   - Do **not** hardcode a subnet in the template — let the ASG control placement
3. In the **User Data** section, add the bootstrap script (see below)
4. Attach an IAM role that allows S3 read access (needed to restore the database backup)

#### User Data Script

```bash
#!/bin/bash
exec > /var/log/userdata.log 2>&1

# Install dependencies
sudo yum install git -y

# Clone application repository
git clone https://<github-username>:<app-password>@github.com/<your-org>/<your-repo>.git /home/ec2-user/app

cd /home/ec2-user/app

# Set up Python virtual environment
python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt

# Set database connection string
export DB_LINK='postgresql://<db-user>:<db-password>@<rds-endpoint>:5432/<db-name>'

# Start the application
gunicorn run:app --bind 0.0.0.0:8000 &
```

> **Note:** Replace all `<placeholder>` values with your actual credentials. Never commit real credentials to a public repository — use AWS Secrets Manager or environment-specific configuration for production workloads.

**Key lessons learned:**
- Always start user data scripts with `#!/bin/bash` — cloud-init requires it
- Avoid special characters (e.g. `!`) in passwords used inside shell scripts
- Logs are available at `/var/log/userdata.log` and `/var/log/cloud-init-output.log`

---

### Step 3: Validate on a Test EC2 Instance

Before finalizing the launch template, test it manually on a temporary public EC2 instance:

1. Launch an instance from the template into a **public subnet** temporarily
2. Add an SSH inbound rule to its security group for your IP
3. SSH in and run the user data commands manually, one by one
4. Restore the database backup from S3:

```bash
# Install PostgreSQL client
sudo yum install -y postgresql15   # use the version matching your RDS engine

# Copy backup from S3
aws s3 cp s3://<your-bucket>/<backup-file>.dump /home/ec2-user/

# Restore into RDS
pg_restore -h <rds-endpoint> -U <db-user> -d <db-name> -v <backup-file>.dump

# Verify tables were restored
psql -h <rds-endpoint> -U <db-user> -d <db-name>
# Inside psql:
# \dt   → list tables
# \du   → list roles
```

5. Verify the application started correctly:

```bash
# Check if gunicorn is running
ps -eo comm,pid | grep gunicorn

# Check if it's listening on port 8000
sudo lsof -i :8000

# Test HTTP response locally
curl -i localhost:8000
```

6. Once everything works, update the launch template with the final user data script
7. Set the working version as the **default** template version
8. **Delete the test EC2 instance** — the ASG will manage instances going forward

---

### Step 4: Create the Auto Scaling Group

1. Go to **EC2 → Auto Scaling Groups → Create Auto Scaling Group**
2. Select your finalized launch template and its default version
3. Network settings:
   - VPC: your custom VPC
   - Subnets: the **private** subnets (not public)
4. Skip the load balancer for now — you'll attach it after creating the ASG
5. Health checks: leave EC2 health checks enabled (default)
6. Group size and scaling:
   - Set minimum, desired, and maximum instance counts
   - Add a **Target Tracking Policy**: scale when average CPU utilization exceeds 50%
7. Create the ASG — it will automatically launch the minimum number of instances using the launch template

---

### Step 5: Create a NAT Gateway

Private EC2 instances need outbound internet access to pull code and install packages.

1. Go to **VPC → NAT Gateways → Create NAT Gateway**
2. Place the NAT Gateway in a **public subnet**
3. Allocate a new Elastic IP
4. Update the **route table** for your private subnets to route `0.0.0.0/0` through the NAT Gateway

---

### Step 6: Create the Application Load Balancer

1. Go to **EC2 → Load Balancers → Create Application Load Balancer**
2. Scheme: **Internet-facing**
3. VPC: your custom VPC; select at least **two Availability Zones** with public subnets
4. Security group: create a new one allowing inbound **port 80** and **port 443** from `0.0.0.0/0`
5. Listeners and routing:
   - Create a **Target Group** first:
     - Target type: **Instances**
     - Protocol: HTTP, Port: **8000** (your application port)
     - Health check path: `/login` (or a path your app responds to with 200)
   - Return to the ALB wizard and attach this target group to the listener on port 80
6. Finish creating the load balancer

**Wait for:**
- Load balancer state → **Active**
- Target group health status → **Healthy**

---

### Step 7: Fix Health Checks (if needed)

If health checks fail:

- Make sure the EC2 security group allows inbound traffic on port 8000 **from the ALB security group** (not from all IPs)
- Make sure the health check path in the target group returns HTTP 200. Update it to a valid path (e.g. `/login`) if needed

---

### Step 8: Test the Application

Access your application via the ALB DNS name over HTTP:

```
http://<alb-dns-name>
```

You should see your application load successfully.

---

### Step 9: Enable HTTPS

1. Ensure you have a public certificate in **AWS Certificate Manager (ACM)** for your domain (e.g. `*.yourdomain.com`)
2. Go to your load balancer → **Listeners → Add listener**
   - Protocol: HTTPS, Port: 443
   - Forward to the same target group
   - Select your ACM certificate
3. In **Route 53**, create an **A record** (alias) pointing your domain to the ALB DNS name
4. Your application is now accessible over HTTPS:

```
https://app.yourdomain.com
```

## Technologies Used

- **AWS VPC** — custom network with public and private subnets
- **AWS RDS** — managed PostgreSQL database
- **AWS EC2 + ASG** — auto-scaling application servers
- **AWS ALB** — internet-facing load balancer with HTTPS termination
- **AWS NAT Gateway** — outbound internet for private instances
- **AWS S3** — database backup storage
- **AWS ACM** — SSL/TLS certificate management
- **AWS Route 53** — DNS management
- **Gunicorn** — Python WSGI application server