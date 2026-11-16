# Stage 5 Post-Mortem & Root Cause Analysis (RCA) — StreamFlix Rehost via AWS Application Migration Service (AWS MGN)
**Document ID**: RCA-STAGE5-MGN-REHOST-POSTMORTEM-20261116  
**Incident / Review Date**: 2026-11-16  
**Classification**: Post-Migration Architecture Review & Failure Mode Analysis  
**Workload**: StreamFlix Core Application Tier (`APP01` Linux KVM to Amazon EC2)  
**Authors**: Enterprise Cloud Migration Architecture Team  

---

## 1. Executive Summary

During the execution of **Stage 5: Enterprise Application Server Migration** using **AWS Application Migration Service (AWS MGN)**, four primary technical blockers were encountered across IAM permission evaluation, VPC network routing, API lifecycle state machines, and EC2 Launch Template version resolution.

While these issues caused transient stalling or misdirection of instances, each was diagnosed in real time using CloudTrail logs, MGN internal replication metrics, and EC2 metadata. Crucially, the **AWS Migration Acceleration Program (MAP) Test Launch gate functioned exactly as designed**: it caught a critical VPC misplacement before any production cutover could occur.

This post-mortem documents the exact symptoms, root causes, technical impact, and definitive remediation steps for each failure mode.

---

## 2. Summary of Failure Modes & Root Causes

| # | Phase | Failure Symptom | Error Code / Log | Root Cause | Remediation Applied |
| :-: | :--- | :--- | :--- | :--- | :--- |
| **1** | **Agent / Init** | Replication Server failed to launch; status `STALLED` | `Client.UnauthorizedOperation` on `iam:PassRole` | IAM role path created as `/` instead of required `/service-role/` prefix | Recreated roles under `--path /service-role/` |
| **2** | **Staging Area** | Replication Server stuck at `AUTHENTICATE_WITH_SERVICE` | Handshake timeout to `mgn.us-east-1.amazonaws.com` | Private staging subnet had no NAT Gateway or Internet egress | Staging subnet moved to public subnet with `createPublicIP: true` + `PRIVATE_IP` data plane |
| **3** | **Pre-Test** | "Cannot launch test instances" popup in AWS Console | `ApiNotAllowedForThisState: state is NOT_READY` | User attempted launch while baseline snapshot `CREATING_SNAPSHOT` was at 85-99% | Waited for snapshot to reach 100% and state to change to `Ready for testing` |
| **4** | **Test Launch** | Test EC2 booted with IP `172.31.6.25` (Default VPC) | Instance unreachable from VPN & RDS (`KeyName: null`) | Updated Launch Template Version 5 was created, but **Version 2 was still Default** | Promoted Version 5 to Default Version; reverted test state in MGN |

---

## 3. Deep-Dive Root Cause Analysis

### Issue 1: IAM Role Path Mismatch (`iam:PassRole` Authorization Failure)

#### Symptom:
After successful installation of the AWS Replication Agent on `APP01` (`10.10.10.20`), the server registered in AWS MGN, but the data replication state immediately fell into **`STALLED`**. The initiation step `CREATE_SECURITY_GROUP` succeeded, but `LAUNCH_REPLICATION_SERVER` failed.

#### CloudTrail Diagnostic Log:
```json
{
  "eventTime": "2026-11-16T17:26:06Z",
  "eventSource": "ec2.amazonaws.com",
  "eventName": "RunInstances",
  "errorCode": "Client.UnauthorizedOperation",
  "errorMessage": "You are not authorized to perform this operation. User: arn:aws:sts::165772574557:assumed-role/AWSServiceRoleForApplicationMigrationService/... is not authorized to perform: iam:PassRole on resource: arn:aws:iam::165772574557:role/AWSApplicationMigrationReplicationServerRole because no identity-based policy allows the iam:PassRole action."
}
```

#### Technical Root Cause:
AWS MGN relies on a Service-Linked Role (`AWSServiceRoleForApplicationMigrationService`) which has the AWS-managed policy `AWSApplicationMigrationServiceRolePolicy` attached. Inspecting version `v9` of this policy revealed:
```json
{
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": [
    "arn:aws:iam::*:role/service-role/AWSApplicationMigrationReplicationServerRole",
    "arn:aws:iam::*:role/service-role/AWSApplicationMigrationConversionServerRole"
  ],
  "Condition": {
    "StringEquals": {
      "iam:PassedToService": "ec2.amazonaws.com"
    }
  }
}
```
Notice the explicit resource pattern: `arn:aws:iam::*:role/service-role/...`.
When the lab roles were provisioned, they were created under the root path `/` (`arn:aws:iam::165772574557:role/AWSApplicationMigrationReplicationServerRole`). Because the IAM policy engine uses strict ARN matching, the absence of the `/service-role/` path prefix caused AWS IAM to deny the `iam:PassRole` request when `mgn.amazonaws.com` called `ec2:RunInstances`.

#### Resolution:
Both roles were deleted and recreated with `--path /service-role/` and re-attached to their respective instance profiles:
```bash
aws iam remove-role-from-instance-profile --instance-profile-name AWSApplicationMigrationReplicationServerRole --role-name AWSApplicationMigrationReplicationServerRole
aws iam delete-role --role-name AWSApplicationMigrationReplicationServerRole

aws iam create-role \
  --path /service-role/ \
  --role-name AWSApplicationMigrationReplicationServerRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam attach-role-policy \
  --role-name AWSApplicationMigrationReplicationServerRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSApplicationMigrationReplicationServerPolicy

aws iam add-role-to-instance-profile \
  --instance-profile-name AWSApplicationMigrationReplicationServerRole \
  --role-name AWSApplicationMigrationReplicationServerRole
```

---

### Issue 2: Control Plane Egress Blocked in Private Staging Subnet

#### Symptom:
Once the IAM issue was resolved, the Replication Server booted successfully (`i-0b24e27b2236cdc40`), but data replication stalled at:
* `AUTHENTICATE_WITH_SERVICE`: **`IN_PROGRESS`** (hanging indefinitely)
* `DOWNLOAD_REPLICATION_SOFTWARE`: `NOT_STARTED`

#### Technical Root Cause:
The Replication Configuration Template initially specified `stagingAreaSubnetId: subnet-094426acfea458e5c` (`streamflix-target-app-private-1a`).
Inspecting the route table for this subnet revealed:
* `10.20.0.0/16` $\to$ `local`
* `10.10.0.0/16` $\to$ `vgw-00ad4f1ba56bb60d5` (VPN)
* **`0.0.0.0/0` $\to$ NONE (No NAT Gateway deployed)**

When an AWS MGN Replication Server boots, it requires outbound HTTPS (Port 443) connectivity to `mgn.us-east-1.amazonaws.com` and Amazon S3 to authenticate and pull replication binaries. Without an outbound route, packets were dropped.

#### Resolution (Hybrid Architecture Best Practice):
1. The **Staging Subnet** was updated to the landing zone's public subnet (`subnet-0f17c60078c74fc05`) with `createPublicIP: true`. This provided immediate, zero-cost outbound connectivity to AWS API endpoints via the existing Internet Gateway (`igw-04aa745bede66f4bc`).
2. Crucially, **`dataPlaneRouting: PRIVATE_IP`** was retained. This ensured that the replication data stream (TCP port 1500) from on-prem `APP01` (`10.10.10.20`) was routed entirely across the private IPsec VPN tunnel, keeping disk data isolated from the public internet.
3. Enabled VGW route propagation on the public route table (`rtb-09f58b24d7bcf61c0`) to permit return routing for `10.10.0.0/16`.

---

### Issue 3: Premature Test Launch During Baseline Snapshot Creation

#### Symptom:
When the 64 GB initial data synchronization reached 100%, attempting to click **Launch test instances** generated an error banner:
> *"This action cannot be performed on the selected server because you can only launch test instances for servers whose lifecycle state is 'Ready for test launch'."*

#### API Diagnostic Error:
```json
{
  "Code": "ConflictException",
  "errors": [
    {
      "code": "ApiNotAllowedForThisState",
      "message": "You cannot call StartTest when SourceServer.lifeCycle.state is NOT_READY",
      "resourceId": "s-3c71f4f9ace86afce",
      "resourceType": "Source server"
    }
  ]
}
```

#### Technical Root Cause:
AWS MGN's state machine enforces a critical data-integrity barrier:
1. `INITIAL_SYNC` transfers the raw disk blocks.
2. Upon reaching 100%, AWS MGN initiates `CREATING_SNAPSHOT` (`snap-09e93a9e62796c736` / `snap-07dadfacebb6bce2b`) to create a consistent point-in-time EBS snapshot.
3. During this snapshot creation (which took ~2 to 3 minutes), `lifeCycle.state` remains `NOT_READY`.
4. AWS MGN strictly denies the `StartTest` API call during this window because attempting to convert an incomplete EBS snapshot would result in a corrupted OS volume that cannot boot.

#### Resolution:
No configuration fix required; this is expected behavior. Once `snap-07dadfacebb6bce2b` reached `100% completed`, AWS MGN automatically transitioned the lifecycle state to **`Ready for testing`** (green), unlocking test instance launches.

---

### Issue 4: Launch Template Version Resolution Failure (Default VPC Launch)

#### Symptom:
The test instance launched successfully (`i-02ca6e61261f78bc1`), but inspection revealed:
* **VPC**: `vpc-0d7dfc3c42d0f39c0` (**AWS Default VPC**, CIDR `172.31.0.0/16`)
* **Subnet**: `subnet-0e3daac08f57e1830`
* **Private IP**: `172.31.6.25`
* **Key Pair**: `None`
* **Security Group**: `default`
The server could not communicate over the Site-to-Site IPsec VPN (which terminates on `vpc-0eacb09847d857983`, `10.20.0.0/16`) and had no path to Amazon RDS PostgreSQL.

#### Technical Root Cause:
Inspecting the versions of EC2 Launch Template `lt-0484d4fc7d27143eb` revealed:

```json
[
  {
    "Version": 5,
    "Default": false,
    "Data": {
      "InstanceType": "t2.medium",
      "KeyName": "CloudForge",
      "Network": [
        {
          "SubnetId": "subnet-0d7fc76b1b17050f0",
          "Groups": ["sg-0c7841ad581251d1d"]
        }
      ]
    }
  },
  {
    "Version": 2,
    "Default": true,
    "Data": {
      "InstanceType": "c5.large",
      "KeyName": null,
      "Network": [
        {
          "AssociatePublicIpAddress": false
        }
      ]
    }
  }
]
```

**The Fatal Flaw**:
In Amazon EC2, Launch Templates are versioned and immutable. When a service (like AWS MGN) launches an instance without an explicit version parameter, **it always resolves to the template's Default Version**.
While the engineer correctly authored Version 4 and Version 5 with the `CloudForge` key pair, target security group, and target subnet, **Version 2 was never demoted from Default**!
Because Version 2 had no `SubnetId` specified, Amazon EC2's standard fallback behavior is to launch the instance into the account's Default VPC (`172.31.0.0/16`).

#### Resolution:
1. Promote Version 5 to the default version:
   ```bash
   aws ec2 modify-launch-template \
     --launch-template-id lt-0484d4fc7d27143eb \
     --default-version 5 \
     --region us-east-1
   ```
2. In the AWS MGN Console, revert the test state:
   * **Source servers** $\to$ select `APP01` $\to$ **Test and cutover** $\to$ **Revert to "Ready for testing"**.
   * *(AWS automatically terminates instance `i-02ca6e61261f78bc1` in the default VPC)*.
3. Relaunch the test instance:
   * **Test and cutover** $\to$ **Launch test instances**.
   * The instance will boot inside `subnet-0d7fc76b1b17050f0` (`10.20.11.x`), securely integrated into the landing zone architecture.

---

## 4. Architectural Lessons Learned & Standard Operating Procedures (SOP)

1. **Always Verify IAM Path Structure for Service-Linked Automation**:
   * Any role intended to be passed by AWS service-linked roles must adhere strictly to documented naming and path constraints (`/service-role/`).
2. **Differentiate Staging Subnet Egress from Target Subnet Placement**:
   * Staging replication servers are temporary data sinks; placing them in a public subnet with `createPublicIP: true` gives cost-free control plane access while `dataPlaneRouting: PRIVATE_IP` guarantees data plane isolation.
   * Target production workloads remain 100% private in isolated subnets behind the Application Load Balancer.
3. **The Launch Template Version Promotion Rule**:
   * Creating a new version in an EC2 Launch Template has **zero effect** until `Actions -> Set default version` is clicked. Always verify `DefaultVersionNumber` before initiating an automated deployment.
4. **The Value of the MAP Testing Gate**:
   * Catching misconfigurations during a Test Launch is a major success, not a failure. It proved that replication remained 100% intact, on-prem `APP01` was unaffected, and the issue was caught with zero downtime.
