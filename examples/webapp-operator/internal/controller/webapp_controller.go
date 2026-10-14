package controller

import (
	"context"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	demoV1 "example.com/webapp-operator/api/v1"
)

// ConditionAvailable 表示被管 Deployment 的可用副本数已达到期望值。
const ConditionAvailable = "Available"

// 固定标签契约：被管 Deployment 及 Pod 都带上 instance 标签，值为 WebApp 名。
const labelInstance = "app.kubernetes.io/instance"

// WebAppReconciler 调谐 WebApp：确保同名 Deployment 存在且与 spec 一致，并回写 status。
type WebAppReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=demo.example.com,resources=webapps,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=demo.example.com,resources=webapps/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create

// Reconcile 把实际状态推向期望状态。调谐必须幂等：重复执行结果一致。
func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. 取 CR；不存在说明已被删除，忽略即可（ownerreference 会级联回收下游）。
	var webapp demoV1.WebApp
	if err := r.Get(ctx, req.NamespacedName, &webapp); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 2. 组装期望的 Deployment。
	desired := r.desiredDeployment(&webapp)

	// 3. 读现有 Deployment：不存在则创建，存在则只在漂移时更新。
	var current appsv1.Deployment
	err := r.Get(ctx, types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}, &current)
	switch {
	case apierrors.IsNotFound(err):
		logger.Info("creating deployment", "deployment", desired.Name)
		if err := r.Create(ctx, desired); err != nil {
			return ctrl.Result{}, err
		}
		// 创建后下一轮再回写 status（此时 Deployment 尚无 status）。
		return ctrl.Result{}, nil
	case err != nil:
		return ctrl.Result{}, err
	}

	if drifted(&current, desired) {
		logger.Info("updating deployment", "deployment", desired.Name)
		current.Spec.Replicas = desired.Spec.Replicas
		current.Spec.Template.Spec.Containers[0].Image = desired.Spec.Template.Spec.Containers[0].Image
		if err := r.Update(ctx, &current); err != nil {
			return ctrl.Result{}, err
		}
	}

	// 4. 回写 status（用观测到的 Deployment 状态，而不是期望值）。
	if err := r.updateStatus(ctx, &webapp, &current); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// desiredDeployment 依据 WebApp 组装被管 Deployment。
func (r *WebAppReconciler) desiredDeployment(webapp *demoV1.WebApp) *appsv1.Deployment {
	replicas := webapp.Spec.Replicas
	port := int32(80)
	if webapp.Spec.Port != nil {
		port = *webapp.Spec.Port
	}

	labels := map[string]string{labelInstance: webapp.Name}

	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "webapp",
							Image: webapp.Spec.Image,
							Ports: []corev1.ContainerPort{{ContainerPort: port}},
						},
					},
				},
			},
		},
	}

	// 关键：ownerReference 指向 CR，删除 CR 时下游被级联回收。
	_ = controllerutil.SetControllerReference(webapp, deploy, r.Scheme)
	return deploy
}

// drifted 判断现有 Deployment 是否偏离期望（只比较本章关心的两个字段）。
func drifted(current, desired *appsv1.Deployment) bool {
	if current.Spec.Replicas == nil || desired.Spec.Replicas == nil {
		return true
	}
	if *current.Spec.Replicas != *desired.Spec.Replicas {
		return true
	}
	return current.Spec.Template.Spec.Containers[0].Image != desired.Spec.Template.Spec.Containers[0].Image
}

// updateStatus 依据被管 Deployment 的真实状态更新 CR 的 status 子资源。
func (r *WebAppReconciler) updateStatus(ctx context.Context, webapp *demoV1.WebApp, deploy *appsv1.Deployment) error {
	webapp.Status.ReadyReplicas = deploy.Status.ReadyReplicas
	webapp.Status.ObservedGeneration = webapp.Generation

	available := deploy.Status.ReadyReplicas >= webapp.Spec.Replicas
	status := metav1.ConditionFalse
	reason := "Unavailable"
	if available {
		status = metav1.ConditionTrue
		reason = "MinimumReplicasAvailable"
	}
	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:               ConditionAvailable,
		Status:             status,
		Reason:             reason,
		ObservedGeneration: webapp.Generation,
		Message:            "被管 Deployment 的可用副本数已对齐期望值",
	})

	return r.Status().Update(ctx, webapp)
}

// SetupWithManager 注册控制器；Owns 让被管 Deployment 的变化也触发调谐。
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&demoV1.WebApp{}).
		Owns(&appsv1.Deployment{}).
		Complete(r)
}
