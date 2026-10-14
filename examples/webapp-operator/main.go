package main

import (
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	demoV1 "example.com/webapp-operator/api/v1"
	"example.com/webapp-operator/internal/controller"
)

var scheme = runtime.NewScheme()

// 控制器只管理这一个命名空间。默认情况下 controller-runtime 的 informer 会在
// 集群级别 list/watch，那就必须给集群级权限；把缓存限定到命名空间后，命名空间级
// 的 Role 就够用了（这就是"命名空间级 Operator"的最小权限做法）。
const watchNamespace = "operator-demo"

func init() {
	// 内置类型（Deployment 等）+ 我们自己的 WebApp。
	_ = clientgoscheme.AddToScheme(scheme)
	_ = demoV1.AddToScheme(scheme)
}

func main() {
	var metricsAddr string
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "metrics 监听地址")

	zapOpts := zap.Options{Development: true}
	zapOpts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zapOpts)))

	// 单副本运行，不需要 leader election。
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		LeaderElection:         false,
		HealthProbeBindAddress: ":8081",
		Cache: cache.Options{
			DefaultNamespaces: map[string]cache.Config{watchNamespace: {}},
		},
	})
	if err != nil {
		ctrl.Log.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if err := (&controller.WebAppReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "unable to create controller", "controller", "WebApp")
		os.Exit(1)
	}

	ctrl.Log.Info("starting webapp-operator")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "problem running manager")
		os.Exit(1)
	}
}
