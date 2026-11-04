package main

import (
	"crypto/sha256"
	"encoding/base64"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func expectedHash(body string) string {
	digest := sha256.Sum256([]byte(body))
	return "'sha256-" + base64.StdEncoding.EncodeToString(digest[:]) + "'"
}

func TestScriptHashesTree(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "nested"), 0755); err != nil {
		t.Fatal(err)
	}
	pages := map[string]string{
		"index.html":       "<script>bootstrap()</script><script src='/external.js'></script>",
		"404.html":         "<script>fallback()</script><script>bootstrap()</script>",
		"nested/page.html": "<script>\r\nother()\r\n</script><script></script>",
		"not-html.js":      "<script>ignored()</script>",
		"nested/data.json": "{}",
	}
	for name, content := range pages {
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := scriptHashes(root)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		expectedHash("bootstrap()"),
		expectedHash("fallback()"),
		expectedHash("\nother()\n"),
		expectedHash(""),
	}
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("hashes = %v, want %v", got, want)
	}
	// Collecting hashes must not alter the source HTML.
	for name, content := range pages {
		after, err := os.ReadFile(filepath.Join(root, name))
		if err != nil || string(after) != content {
			t.Fatalf("%s changed: %q, %v", name, after, err)
		}
	}
}

func TestScriptHashesFileAndFailures(t *testing.T) {
	root := t.TempDir()
	if _, err := scriptHashes(root); err == nil {
		t.Fatal("empty HTML tree should fail")
	}
	if _, err := scriptHashes(filepath.Join(root, "missing")); err == nil {
		t.Fatal("missing file should fail")
	}
	page := filepath.Join(root, "index.html")
	if err := os.WriteFile(page, []byte("<script>bootstrap()</script>"), 0644); err != nil {
		t.Fatal(err)
	}
	got, err := scriptHashes(page)
	if err != nil || !slices.Equal(got, []string{expectedHash("bootstrap()")}) {
		t.Fatalf("file hashes = %v, %v", got, err)
	}
	if err := os.WriteFile(page, []byte{0xff}, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := scriptHashes(root); err == nil {
		t.Fatal("invalid UTF-8 HTML should fail")
	}
}
