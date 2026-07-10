package podbuilder

import (
	"testing"

	apiv1 "k8s.io/api/core/v1"
)

func TestPluginContainerGetsWESIdentityEnvFrom(t *testing.T) {
	c := BuildPluginContainer("image-sampler2", "waggle/image-sampler2:1.0.0", nil)

	if len(c.EnvFrom) != 1 {
		t.Fatalf("expected exactly 1 EnvFrom source, got %d", len(c.EnvFrom))
	}
	ref := c.EnvFrom[0].ConfigMapRef
	if ref == nil {
		t.Fatal("EnvFrom[0].ConfigMapRef is nil; expected a ConfigMap projection")
	}
	if ref.Name != "wes-identity" {
		t.Errorf("EnvFrom ConfigMap name = %q, want %q", ref.Name, "wes-identity")
	}
	if ref.Optional == nil || *ref.Optional != true {
		t.Errorf("EnvFrom ConfigMap Optional = %v, want true (must not block scheduling if CM absent)", ref.Optional)
	}
}

func TestChangeIsAdditive_StandardEnvAndMountsPreserved(t *testing.T) {
	c := BuildPluginContainer("p", "img", nil)

	// standard WAGGLE_* env still present
	want := map[string]bool{
		"WAGGLE_PLUGIN_HOST": false, "WAGGLE_GPS_SERVER": false,
		"WAGGLE_SCOREBOARD": false, "WAGGLE_APP_ID": false,
	}
	for _, e := range c.Env {
		if _, ok := want[e.Name]; ok {
			want[e.Name] = true
		}
	}
	for k, seen := range want {
		if !seen {
			t.Errorf("standard env %q was dropped by the change", k)
		}
	}

	// standard volume mounts still present
	mounts := map[string]string{}
	for _, m := range c.VolumeMounts {
		mounts[m.Name] = m.MountPath
	}
	if mounts["waggle-data-config"] != "/run/waggle/data-config.json" {
		t.Errorf("data-config mount missing/changed: %v", mounts)
	}
	if mounts["uploads"] != "/run/waggle/uploads" {
		t.Errorf("uploads mount missing/changed: %v", mounts)
	}
}

func TestUserEnvPrecedesStandardEnv(t *testing.T) {
	// upstream invariant: "We put user environmental variables first, so that they
	// don't override our environmental variables." EnvFrom is applied by kubelet
	// BEFORE the container's Env list, so explicit Env still wins over the ConfigMap
	// -- exactly the precedence pywaggle2 wants (explicit > injected).
	user := []apiv1.EnvVar{{Name: "MY_PLUGIN_FLAG", Value: "1"}}
	c := BuildPluginContainer("p", "img", user)

	if len(c.Env) == 0 || c.Env[0].Name != "MY_PLUGIN_FLAG" {
		t.Fatalf("user env should be first; got %+v", c.Env)
	}
}

func TestEnvFromPrecedenceContract(t *testing.T) {
	// Document + lock the k8s semantics we rely on: container.Env entries override
	// EnvFrom entries of the same name. So if a plugin (or the scheduler) ever sets
	// WAGGLE_NODE_VSN explicitly in Env, it wins over the wes-identity ConfigMap
	// value. This is why layering EnvFrom UNDER Env is safe.
	//
	// We can't run a kubelet here, but we assert the structural ordering the
	// contract depends on: Env is a discrete list and EnvFrom is separate, so the
	// scheduler retains full control to override per-var when needed.
	c := BuildPluginContainer("p", "img", []apiv1.EnvVar{{Name: "WAGGLE_NODE_VSN", Value: "OVERRIDE"}})
	found := false
	for _, e := range c.Env {
		if e.Name == "WAGGLE_NODE_VSN" && e.Value == "OVERRIDE" {
			found = true
		}
	}
	if !found {
		t.Error("explicit WAGGLE_NODE_VSN in Env not preserved; override path broken")
	}
}
