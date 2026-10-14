package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WebAppSpec 定义 WebApp 的期望状态。
type WebAppSpec struct {
	// Image 是控制器创建的 Deployment 所使用的容器镜像。
	// +kubebuilder:validation:MinLength=1
	Image string `json:"image"`

	// Replicas 是期望的副本数。
	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=10
	Replicas int32 `json:"replicas"`

	// Port 是容器暴露的端口，可选。
	// +optional
	Port *int32 `json:"port,omitempty"`
}

// WebAppStatus 定义 WebApp 的观测状态。
type WebAppStatus struct {
	// ReadyReplicas 来自被管 Deployment 的 status。
	// +optional
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// ObservedGeneration 是最近一次调谐到的 .metadata.generation。
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Conditions 描述 WebApp 的当前状况。
	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=wa
// +kubebuilder:printcolumn:name="Image",type=string,JSONPath=`.spec.image`
// +kubebuilder:printcolumn:name="Replicas",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// WebApp 是 webapps API 的 Schema。
type WebApp struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebAppSpec   `json:"spec,omitempty"`
	Status WebAppStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WebAppList 包含 WebApp 的列表。
type WebAppList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WebApp `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WebApp{}, &WebAppList{})
}
