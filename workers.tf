resource "aws_cloudformation_stack" "workers" {
  count = var.worker_group_count
  name = replace(
    "${aws_eks_cluster.this.name}-${lookup(var.worker_groups[count.index], "name", count.index)}",
    "/[^-a-zA-Z0-9]/",
    "-",
  )
  template_body = <<EOF
---
AWSTemplateFormatVersion: "2010-09-09"
Description: Terraform-managed CF Stack for Auto-Scaling Group
Resources:
  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: ${aws_eks_cluster.this.name}-${lookup(var.worker_groups[count.index], "name", count.index)}
      VPCZoneIdentifier: ${jsonencode(
  split(
    ",",
    coalesce(
      lookup(var.worker_groups[count.index], "subnets", ""),
      join(",", var.subnets),
    ),
  ),
  )}
      LaunchConfigurationName: ${element(aws_launch_configuration.workers.*.id, count.index)}
      MinSize: ${lookup(
  var.worker_groups[count.index],
  "asg_min_size",
  local.workers_group_defaults["asg_min_size"],
  )}
      MaxSize: ${lookup(
  var.worker_groups[count.index],
  "asg_max_size",
  local.workers_group_defaults["asg_max_size"],
  )}
      Tags: ${jsonencode(
  concat(
    [
      {
        "Key"               = "Name"
        "Value"             = "${aws_eks_cluster.this.name}-${lookup(var.worker_groups[count.index], "name", count.index)}-eks_asg"
        "PropagateAtLaunch" = "True"
      },
      {
        "Key"               = "kubernetes.io/cluster/${aws_eks_cluster.this.name}"
        "Value"             = "owned"
        "PropagateAtLaunch" = "True"
      },
    ],
    local.asg_tags,
  ),
  )}
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MaxBatchSize: ${lookup(
  var.worker_groups[count.index],
  "asg_rolling_update_max_batch_size",
  local.workers_group_defaults["asg_rolling_update_max_batch_size"],
  )}
        MinInstancesInService: ${lookup(
  var.worker_groups[count.index],
  "asg_rolling_update_min_instances_in_service",
  local.workers_group_defaults["asg_rolling_update_min_instances_in_service"],
)}
        SuspendProcesses:
          - HealthCheck
          - ReplaceUnhealthy
          - AZRebalance
          - AlarmNotification
          - ScheduledActions
Outputs:
  AutoScalingGroupName:
    Description: The name of the Auto-Scaling Group
    Value: !Ref AutoScalingGroup
EOF

}

data "template_file" "workers_names" {
  count    = var.worker_group_count
  template = aws_cloudformation_stack.workers[count.index].outputs["AutoScalingGroupName"]
}

resource "aws_launch_configuration" "workers" {
  name_prefix = "${aws_eks_cluster.this.name}-${lookup(var.worker_groups[count.index], "name", count.index)}"
  associate_public_ip_address = lookup(
    var.worker_groups[count.index],
    "public_ip",
    local.workers_group_defaults["public_ip"],
  )
  security_groups = [local.worker_security_group_id, var.worker_additional_security_group_ids, compact(
    split(
      ",",
      lookup(
        var.worker_groups[count.index],
        "additional_security_group_ids",
        local.workers_group_defaults["additional_security_group_ids"],
      ),
    ),
  )]
  iam_instance_profile = element(aws_iam_instance_profile.workers.*.id, count.index)
  image_id = lookup(
    var.worker_groups[count.index],
    "ami_id",
    local.workers_group_defaults["ami_id"],
  )
  instance_type = lookup(
    var.worker_groups[count.index],
    "instance_type",
    local.workers_group_defaults["instance_type"],
  )
  key_name = lookup(
    var.worker_groups[count.index],
    "key_name",
    local.workers_group_defaults["key_name"],
  )
  user_data_base64 = base64encode(element(data.template_file.userdata.*.rendered, count.index))
  ebs_optimized = lookup(
    var.worker_groups[count.index],
    "ebs_optimized",
    lookup(
      local.ebs_optimized,
      lookup(
        var.worker_groups[count.index],
        "instance_type",
        local.workers_group_defaults["instance_type"],
      ),
      false,
    ),
  )
  enable_monitoring = lookup(
    var.worker_groups[count.index],
    "enable_monitoring",
    local.workers_group_defaults["enable_monitoring"],
  )
  spot_price = lookup(
    var.worker_groups[count.index],
    "spot_price",
    local.workers_group_defaults["spot_price"],
  )
  placement_tenancy = lookup(
    var.worker_groups[count.index],
    "placement_tenancy",
    local.workers_group_defaults["placement_tenancy"],
  )
  count = var.worker_group_count

  lifecycle {
    create_before_destroy = true
  }

  root_block_device {
    volume_size = lookup(
      var.worker_groups[count.index],
      "root_volume_size",
      local.workers_group_defaults["root_volume_size"],
    )
    volume_type = lookup(
      var.worker_groups[count.index],
      "root_volume_type",
      local.workers_group_defaults["root_volume_type"],
    )
    iops = lookup(
      var.worker_groups[count.index],
      "root_iops",
      local.workers_group_defaults["root_iops"],
    )
    delete_on_termination = true
  }
}

resource "aws_security_group" "workers" {
  name_prefix = aws_eks_cluster.this.name
  description = "Security group for all nodes in the cluster."
  vpc_id      = var.vpc_id
  count       = var.worker_create_security_group ? 1 : 0
  tags = merge(
    var.tags,
    {
      "Name"                                               = "${aws_eks_cluster.this.name}-eks_worker_sg"
      "kubernetes.io/cluster/${aws_eks_cluster.this.name}" = "owned"
    },
  )
}

resource "aws_security_group_rule" "workers_egress_internet" {
  description       = "Allow nodes all egress to the Internet."
  protocol          = "-1"
  security_group_id = aws_security_group.workers[0].id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 0
  type              = "egress"
  count             = var.worker_create_security_group ? 1 : 0
}

resource "aws_security_group_rule" "workers_ingress_self" {
  description              = "Allow node to communicate with each other."
  protocol                 = "-1"
  security_group_id        = aws_security_group.workers[0].id
  source_security_group_id = aws_security_group.workers[0].id
  from_port                = 0
  to_port                  = 65535
  type                     = "ingress"
  count                    = var.worker_create_security_group ? 1 : 0
}

resource "aws_security_group_rule" "workers_ingress_cluster" {
  description              = "Allow workers Kubelets and pods to receive communication from the cluster control plane."
  protocol                 = "tcp"
  security_group_id        = aws_security_group.workers[0].id
  source_security_group_id = local.cluster_security_group_id
  from_port                = var.worker_sg_ingress_from_port
  to_port                  = 65535
  type                     = "ingress"
  count                    = var.worker_create_security_group ? 1 : 0
}

resource "aws_security_group_rule" "workers_ingress_cluster_https" {
  description              = "Allow pods running extension API servers on port 443 to receive communication from cluster control plane."
  protocol                 = "tcp"
  security_group_id        = aws_security_group.workers[0].id
  source_security_group_id = local.cluster_security_group_id
  from_port                = 443
  to_port                  = 443
  type                     = "ingress"
  count                    = var.worker_create_security_group ? 1 : 0
}

resource "aws_iam_role" "workers" {
  name_prefix           = aws_eks_cluster.this.name
  assume_role_policy    = data.aws_iam_policy_document.workers_assume_role_policy.json
  force_detach_policies = true
}

resource "aws_iam_instance_profile" "workers" {
  name_prefix = aws_eks_cluster.this.name
  role = lookup(
    var.worker_groups[count.index],
    "iam_role_id",
    local.workers_group_defaults["iam_role_id"],
  )
  count = var.worker_group_count
}

resource "aws_iam_role_policy_attachment" "workers_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.workers.name
}

resource "aws_iam_role_policy_attachment" "workers_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.workers.name
}

resource "aws_iam_role_policy_attachment" "workers_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.workers.name
}

resource "null_resource" "tags_as_list_of_maps" {
  count = length(keys(var.tags))

  triggers = {
    "Key"               = element(keys(var.tags), count.index)
    "Value"             = element(values(var.tags), count.index)
    "PropagateAtLaunch" = "True"
  }
}

resource "aws_iam_role_policy_attachment" "workers_autoscaling" {
  policy_arn = aws_iam_policy.worker_autoscaling.arn
  role       = aws_iam_role.workers.name
}

resource "aws_iam_policy" "worker_autoscaling" {
  name_prefix = "eks-worker-autoscaling-${aws_eks_cluster.this.name}"
  description = "EKS worker node autoscaling policy for cluster ${aws_eks_cluster.this.name}"
  policy      = data.aws_iam_policy_document.worker_autoscaling.json
}

data "aws_iam_policy_document" "worker_autoscaling" {
  statement {
    sid    = "eksWorkerAutoscalingAll"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "eksWorkerAutoscalingOwn"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/kubernetes.io/cluster/${aws_eks_cluster.this.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }
  }
}

