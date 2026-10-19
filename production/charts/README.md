# =============================================================================
# charts/ —— Helm chart 包（本地 CHARTS_MODE=local 时用）
# =============================================================================
# 这个目录放离线 chart 打包（*.tgz），供 `CHARTS_MODE=local`（默认）时使用。
#
# 为什么默认走 local:
#   生产环境/受限网络往往访问不到 Helm 仓库；离线 chart 是最可靠的方式。
#   需要从仓库拉取时，把 `config/cluster.env` 的 `CHARTS_MODE` 改成 `repo`，
#   addons 阶段会用 `helm repo add` + `helm upgrade --install <chart>` 的方式安装。
#
# 需要哪些 chart（版本在 `config/cluster.env` 里配）:
#   ingress-nginx-{INGRESS_CHART_VERSION}.tgz
#   cert-manager-{CERT_MANAGER_CHART_VERSION}.tgz
#   rancher-{RANCHER_CHART_VERSION}.tgz
#
# 怎么准备:
#   在**能访问互联网**的机器上跑:
#     ./production/scripts/fetch-artifacts.sh
#   它会把 chart 下载到本目录，并把 k3s/helm 二进制下到 ../artifacts/。
#
# ⚠️ *.tgz 不入 git（体积大，且版本在 cluster.env 里指定）。本目录只放 README。
#
# 校验: bootstrap.sh 的 05-preflight 阶段会检查所需 chart 是否齐全，
#      缺了会报错并提示"先跑 fetch-artifacts.sh"。
# =============================================================================
