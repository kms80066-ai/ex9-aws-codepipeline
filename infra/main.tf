# Amazon Linux 2023 최신 AMI 조회
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# data "aws_security_group" "security_group_alb" {
#   filter {
#     name   = "tag:Name"
#     values = ["${local.tag_header}external-alb-sg"]
#   }
# }

# data "aws_security_group" "security_group_ssh" {
#   filter {
#     name   = "tag:Name"
#     values = ["${local.tag_header}ssh-sg"]
#   }
# }

# 인스턴스에 추가할 보안 그룹
data "aws_security_groups" "security_groups" {
  filter {
    name = "tag:Name"
    values = [
      "${local.tag_header}external-alb-sg",
      "${local.tag_header}ssh-sg"
    ]
  }
}

output "information" {
  value = [
    local.vpc_id,
    data.aws_security_groups.security_groups.ids
  ]
}

# ============================================================
# Pipeline 저장용 S3 Bucket
# ============================================================
# byte_length에 정의된 자리수의 임의 숫자 반환
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Pipeline 구성에 필요한 배포 파일 저장소 생성
resource "aws_s3_bucket" "pipeline_bucket" {
  bucket        = "${local.tag_header}pipeline-bucket-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    "Name" = "${local.tag_header}pipeline-bucket-${random_id.bucket_suffix.hex}"
  }
}

# 생성된 버킷의 버전관리 활성화(CodePipeline에서 필수 요구사항)
resource "aws_s3_bucket_versioning" "pipeline_bucket_versioning" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 퍼블릭 액세스 전체 차단 (보안 규정 준수)
resource "aws_s3_bucket_public_access_block" "pipeline_bucket_public_access" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# 서버측 기본 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_bucket_encryption" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-53
    }
  }
}

# ============================================================
# 서비스에 사용할 역할 생성
# ============================================================
resource "aws_iam_role" "node_role_asg" {
  name = "${local.tag_header}AmazonASGNodeEC2-Role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole" # 신뢰관계 허용(IAM Role을 임시로 획득하여 권한을 행사: 임시권한 허용)
    }]
  })
}

# 정책 연결
resource "aws_iam_role_policy_attachment" "node_polices_asg" {
  for_each = toset(local.ec2_policy_arns) # ECR, S3, SSM

  role       = aws_iam_role.node_role_asg.name
  policy_arn = each.value
}

# 인스턴스 프로필 생성
resource "aws_iam_instance_profile" "node_profile_asg" {
  name = "${local.tag_header}ASGNodeInstance-profile"
  role = aws_iam_role.node_role_asg.name
}

# ================================================================================
# CodeDeploy 역할(Role)
# --------------------------------------------------------------------------------
# 역할 생성
resource "aws_iam_role" "codedeploy_role" {
  name = "${local.tag_header}AmazonCodeDeployService-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole" # IAM Role을 임시로 획득하여 권한을 행사할 수 있도록 허용
    }]
  })
}

# 관리형 정책을 역할에 연결
resource "aws_iam_role_policy_attachment" "codedeploy_policy" {
  role       = aws_iam_role.codedeploy_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# ================================================================================
# CodePipeline 서비스에서 사용할 IAM Role 생성
# --------------------------------------------------------------------------------
# 역할 생성
resource "aws_iam_role" "codepipeline_role" {
  name = "${local.tag_header}AmazonCodePipelineService-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole" # IAM Role을 임시로 획득하여 권한을 행사할 수 있도록 허용
    }]
  })
}

# 각 서비스에 대한 접근권한(정책) 생성과 연결(role 부분이 있어서)을 같이 
resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "${local.tag_header}CodePipelineSecvicePolicy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # [보완] Artifact Bucket 위치/ACL 조회 권한 추가, 새 버킷으로 범위 제한
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:GetBucketAcl",
          # "s3:GetBucketLocation",
          # "s3:PutObjectAcl",
          "s3:PutObject"
        ]
        Resource = "*"
      },
      {
        # [원본 유지] 강사님 정책에 포함됨. 현재 Pipeline에는 Build Stage 없음.
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"]
        Resource = "*"
      },
      {
        # [보완] CodeDeploy 액션에 필요한 조회 권한 추가
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          # "codedeploy:GetDeploymentGroup",
          # "codedeploy:ListDeployments",
          # "codedeploy:ListDeploymentGroups",
          # "codedeploy:ListDeploymentConfigs",
          "codedeploy:RegisterApplicationRevision"
        ]
        Resource = "*"
      }
    ]
  })
}


# ============================================================
# 시작템플릿 & Userdata
# ============================================================
# 템플릿 생성
resource "aws_launch_template" "asg_lt" {
  name_prefix            = "${local.tag_header}-"
  image_id               = local.ami_id #al2023
  instance_type          = "t3.small"
  key_name               = local.key_name
  vpc_security_group_ids = local.security_groups_ids

  # 기본 버전 지정 방법
  update_default_version = var.default_version == "latest" ? true : false
  default_version        = var.default_version != "latest" ? tostring(var.default_version) : null

  # 인스턴스에 역할
  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile_asg.name
  }

  # userdata
  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf update -y
              # ruby: CodeDeploy서비스 개발 언어, codedeploy-agent 설치를 위해 반드시 필요
              dnf install -y ruby wget docker

              systemctl start docker
              systemctl enable docker
              usermod -aG docker ec2-user

              cd /tmp
              wget https://aws-codedeploy-ap-south-1.s3.ap-south-1.amazonaws.com/latest/install
              chmod +x ./install
              ./install auto

              systemctl start codedeploy-agent
              systemctl enable codedeploy-agent
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.tag_header}asg-node-instance"
    }
  }

}

# ============================================================
# Auto Scaling Group
# ============================================================
resource "aws_autoscaling_group" "asg" {
  name                = "${local.tag_header}codedeploy-asg"
  min_size            = 1
  max_size            = 3
  desired_capacity    = 2
  vpc_zone_identifier = local.private_subnet_ids

  launch_template {
    id      = aws_launch_template.asg_lt.id
    version = "$Latest"
  }
}

# ============================================================
# CodeDeploy Application & Deployment Group
# ============================================================
resource "aws_codedeploy_app" "app" {
  name = "${local.tag_header}asg-codedeploy-app"
  # 배포 대상 정의: Server / Lambda / ECS
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "dg" {
  deployment_group_name = "${local.tag_header}asg-deployment-group"
  # codedeploy_app 리소스 이름
  app_name = aws_codedeploy_app.app.name
  # codedeploy 서비스에 추가해줄 역할
  service_role_arn = aws_iam_role.codedeploy_role.arn

  # 배포 대상 정의
  autoscaling_groups = [aws_autoscaling_group.asg.name]
  # 배포 전략 지정
  # "OneAtATime": 한대씩 순차 배포
  # "HalfAtATime": 대상 인스턴스의 50%를 먼저 배포 후 나머지 배포
  deployment_config_name = "CodeDeployDefault.AllAtOnce" # 타겟 인스턴스 전체에 동시에 한 번에 배포하는 방식(전체 중단 -> 동시 배포 -> 동시 재시작)
}
# ============================================================
# 연결 리소스 생성 및 CodePipeline 리소스 생성
# ============================================================
# AWS - GitHub 간 CodeStar Connection 생성
resource "aws_codestarconnections_connection" "github" {
  name          = "${local.tag_header}github-connection"
  provider_type = "GitHub"
}

# AWS Codepipeline 생성
resource "aws_codepipeline" "codepipeline" {
  name = "${local.tag_header}asg-cicd-pipeline"

  # codepipeline Role 정의
  role_arn = aws_iam_role.codepipeline_role.arn

  # 소스코드 정보
  artifact_store {
    # 앞서 생성한 Pipeline 전용 S3 버킷 이름 지정
    location = aws_s3_bucket.pipeline_bucket.bucket

    # 아티팩트 저장소 유형 지정
    type = "S3"
  }
  # --------------------
  # Stage 1 : Source
  stage {
    name = "Source"

    action {
      name     = "Source"
      category = "Source"
      owner    = "AWS"                      # 액션 제공자(AWS에서 제공하는 서비스 활용)
      provider = "CodeStarSourceConnection" # GitHub V2 액션과 연동 표준인 "CodeStarSourceConnection"사용
      version  = "1"
      # ZIP 소스 압축파일을 다음 스테이지로 전달할 전달용 아티팩트 이름 선언
      output_artifacts = ["source_output"]

      # GitHub 연동을 위한 속성값 정의
      configuration = {
        # GitHub와 CodeDeploy를 연결하는 연결 객체 정의
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = local.github_repository_id
        BranchName       = "main"
      }
    }
  }
  # --------------------
  # Stage 2 : Deploy
  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"      # 배포에 사용할 AWS 서비스 지정
      input_artifacts = ["source_output"] # Stage 1 의 output_artifacts에 정의된 이름
      version         = "1"

      configuration = {
        # 배포서비스(CodeDeploy Application) 이름
        ApplicationName = aws_codedeploy_app.app.name
        # 배포를 진행할 CodeDeploy Deployment Group 이름
        DeploymentGroupName = aws_codedeploy_deployment_group.dg.deployment_group_name
      }
    }
  }

}
