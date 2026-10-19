# =============================================================================
# terraform/ —— VM 模板（本期只落模板文件，不落 terraform 代码）
# =============================================================================
# 现状: 本期（bootstrap.sh 一次性装好 3 台裸机）**不依赖** terraform。
#       这个目录只放"动态扩容时虚拟机从哪里来"的模板定义，供后续接入 Terraform 参考。
#
# 为什么现在不写 terraform:
#   1. 本仓库的场景是"已有 N 台物理/虚拟服务器，装好系统，交给 bootstrap.sh"
#   2. Terraform 涉及 vSphere/OpenStack/云厂商等具体 provider，属于各环境专属配置
#   3. 生产中 VM 通常由模板批量克隆（vSphere template / OpenStack image），
#      不是"terraform apply 一台建一台"
#
# 后续接入 Terraform 时:
#   1. 在 `vm_template.yml.example` 基础上补充 provider/main.tf/variables.tf
#   2. 虚机创建后，把 hostname/ip/role 写入 `config/ipam.yml`
#   3. 跑 `./production/scale.sh apply` 扩容
#
# 文件:
#   vm_template.yml.example  VM 模板的参数化示例（CPU/内存/磁盘/镜像来源）
# =============================================================================
