# 第一段：借 alpine 提供 CA 证书（控制器要访问 apiserver，需要校验证书链）。
# alpine:3.20 体积小，且这里只为了取一个文件，不会进入最终镜像。
FROM alpine:3.20 AS certs

# 第二段：最终镜像。scratch 是空镜像，只放静态二进制 + CA 证书，
# 没有 shell、没有包管理器，攻击面最小。
FROM scratch

COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY bin/webapp-operator /webapp-operator

# 以非 root 用户运行，对应 config/manager/deployment.yaml 里的 runAsNonRoot: true。
# scratch 里没有 /etc/passwd，用数字 UID/GID 即可（65532 是 k8s 生态常用的 nonroot）。
USER 65532:65532

ENTRYPOINT ["/webapp-operator"]
