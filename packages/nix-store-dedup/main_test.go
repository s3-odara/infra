//go:build linux

package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"unsafe"
)

const (
	validHashA = "0123456789abcdfghijklmnpqrsvwxyz"
	validHashB = "zyxwvsrqpnmlkjihgfdcba9876543210"
	validHashC = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
)

func TestLinuxABILayout(t *testing.T) {
	if got := unsafe.Sizeof(openHow{}); got != 24 {
		t.Errorf("sizeof(openHow) = %d, want 24", got)
	}
	if got := unsafe.Sizeof(fileDedupeRangeInfo{}); got != 32 {
		t.Errorf("sizeof(fileDedupeRangeInfo) = %d, want 32", got)
	}
	if got := unsafe.Sizeof(fileDedupeRangeSingle{}); got != 24+32 {
		t.Errorf("sizeof(fileDedupeRangeSingle) = %d, want 56", got)
	}
	if got := unsafe.Offsetof(fileDedupeRangeSingle{}.Info); got != 24 {
		t.Errorf("offsetof(fileDedupeRangeSingle.Info) = %d, want 24", got)
	}
	if got := unsafe.Sizeof(fiemapHeader{}); got != 32 {
		t.Errorf("sizeof(fiemapHeader) = %d, want 32", got)
	}
	if got := unsafe.Sizeof(fiemapExtent{}); got != 56 {
		t.Errorf("sizeof(fiemapExtent) = %d, want 56", got)
	}
	if got := unsafe.Offsetof(fiemapRequest{}.Extents); got != 32 {
		t.Errorf("offsetof(fiemapRequest.Extents) = %d, want 32", got)
	}
}

func TestIsStoreEntryName(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{validHashA + "-glibc-2.40", true},
		{validHashB + "-foo.conf", true},
		{".links", false},
		{validHashA + "-glibc-2.40.lock", false},
		{validHashA + "-glibc-2.40.chroot", false},
		// 'e', 'o', 't', 'u' are not in nixbase32.
		{"e123456789abcdfghijklmnpqrsvwxyz-bad", false},
		{"o123456789abcdfghijklmnpqrsvwxyz-bad", false},
		{"t123456789abcdfghijklmnpqrsvwxyz-bad", false},
		{"u123456789abcdfghijklmnpqrsvwxyz-bad", false},
		{validHashA + "-", false},
		{"short-name", false},
	}

	for _, tc := range cases {
		if got := isStoreEntryName(tc.name); got != tc.want {
			t.Errorf("isStoreEntryName(%q) = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestExtentsEqual(t *testing.T) {
	base := []fiemapExtent{
		{Logical: 0, Physical: 1000, Length: 4096},
		{Logical: 4096, Physical: 9000, Length: 8192, Flags: fiemapExtentLast},
	}

	if !extentsEqual(base, base) {
		t.Fatalf("expected identical extents to be equal")
	}
	if extentsEqual(nil, nil) {
		t.Fatalf("expected empty extents to be unequal")
	}

	diffPhys := []fiemapExtent{
		{Logical: 0, Physical: 2000, Length: 4096},
		{Logical: 4096, Physical: 9000, Length: 8192, Flags: fiemapExtentLast},
	}
	if extentsEqual(base, diffPhys) {
		t.Fatalf("expected different physical offsets to be unequal")
	}

	inline := []fiemapExtent{
		{Logical: 0, Physical: 1000, Length: 4096, Flags: fiemapExtentDataInline},
	}
	if extentsEqual(inline, inline) {
		t.Fatalf("expected inline extents to be treated as unequal")
	}

	delalloc := []fiemapExtent{
		{Logical: 0, Physical: 1000, Length: 4096, Flags: fiemapExtentDelalloc},
	}
	if extentsEqual(delalloc, delalloc) {
		t.Fatalf("expected delalloc extents to be treated as unequal")
	}
}

func writeFileSized(t *testing.T, p string, content byte, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", p, err)
	}
	buf := bytes.Repeat([]byte{content}, size)
	if err := os.WriteFile(p, buf, 0o444); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
}

func TestRunDedupeAndSecurity(t *testing.T) {
	tmp := t.TempDir()
	hostStore := filepath.Join(tmp, "host-store")
	containersDir := filepath.Join(tmp, "containers")
	guestAStore := filepath.Join(containersDir, "user-1000_alpha", "rootfs", "nix", "store")
	guestBStore := filepath.Join(containersDir, "user-1000_beta", "rootfs", "nix", "store")

	if err := os.MkdirAll(hostStore, 0o755); err != nil {
		t.Fatal(err)
	}

	// Shared directory store path across host + alpha + beta.
	dirPkg := validHashA + "-pkg"
	writeFileSized(t, filepath.Join(hostStore, dirPkg, "bin", "tool"), 'a', 8192)
	writeFileSized(t, filepath.Join(guestAStore, dirPkg, "bin", "tool"), 'a', 8192)
	writeFileSized(t, filepath.Join(guestBStore, dirPkg, "bin", "tool"), 'a', 8192)

	// Small file below min-size should be ignored.
	writeFileSized(t, filepath.Join(hostStore, dirPkg, "small"), 's', 128)
	writeFileSized(t, filepath.Join(guestAStore, dirPkg, "small"), 's', 128)

	// Symlink in guest should be safely skipped by openat2(RESOLVE_NO_SYMLINKS).
	writeFileSized(t, filepath.Join(hostStore, dirPkg, "escape"), 'e', 8192)
	secretFile := filepath.Join(tmp, "outside-secret")
	writeFileSized(t, secretFile, 'e', 8192)
	if err := os.Symlink(secretFile, filepath.Join(guestAStore, dirPkg, "escape")); err != nil {
		t.Fatal(err)
	}

	// Single-file store path shared only between alpha and beta (not on host).
	singlePkg := validHashB + "-single.bin"
	writeFileSized(t, filepath.Join(guestAStore, singlePkg), 'b', 4096)
	writeFileSized(t, filepath.Join(guestBStore, singlePkg), 'b', 4096)

	// Unique store path only on host should not be scanned.
	uniquePkg := validHashC + "-only-host"
	writeFileSized(t, filepath.Join(hostStore, uniquePkg, "data"), 'c', 8192)

	var dedupeCalls int
	extentReadsByIno := make(map[uint64]int)
	mockOps := ops{
		readExtents: func(fd int, size uint64) ([]fiemapExtent, bool, error) {
			var st syscall.Stat_t
			if err := syscall.Fstat(fd, &st); err != nil {
				return nil, false, err
			}
			extentReadsByIno[st.Ino]++
			return []fiemapExtent{
				{Logical: 0, Physical: st.Ino * 4096, Length: size, Flags: fiemapExtentLast},
			}, true, nil
		},
		dedupeFile: func(srcFD, dstFD int, size int64) (dedupeResult, error) {
			dedupeCalls++
			return dedupeResult{bytesDeduped: uint64(size)}, nil
		},
	}

	var logBuf bytes.Buffer
	st, err := run(config{
		hostStore:          hostStore,
		incusContainersDir: containersDir,
		minSize:            4096,
		dryRun:             false,
		verbose:            true,
	}, mockOps, &logBuf)
	if err != nil {
		t.Fatalf("run returned error: %v", err)
	}

	if st.stores != 3 {
		t.Errorf("stores = %d, want 3", st.stores)
	}
	if st.sharedStorePaths != 2 {
		t.Errorf("sharedStorePaths = %d, want 2", st.sharedStorePaths)
	}
	// bin/tool (host->alpha, host->beta) + single.bin (alpha->beta) = 3 deduped files.
	if dedupeCalls != 3 || st.filesDeduped != 3 || st.filesScanned != 3 {
		t.Errorf("dedupeCalls=%d filesDeduped=%d filesScanned=%d, want 3", dedupeCalls, st.filesDeduped, st.filesScanned)
	}
	wantBytes := uint64(8192*2 + 4096)
	if st.bytesDeduped != wantBytes {
		t.Errorf("bytesDeduped = %d, want %d", st.bytesDeduped, wantBytes)
	}
	// escape (symlink in alpha, missing in beta) = 2 skipped.
	if st.filesSkipped != 2 {
		t.Errorf("filesSkipped = %d, want 2 (logs: %s)", st.filesSkipped, logBuf.String())
	}

	// Host bin/tool has 2 destinations (alpha, beta) but must only query FIEMAP once.
	var hostToolStat syscall.Stat_t
	if err := syscall.Stat(filepath.Join(hostStore, dirPkg, "bin", "tool"), &hostToolStat); err != nil {
		t.Fatal(err)
	}
	if got := extentReadsByIno[hostToolStat.Ino]; got != 1 {
		t.Errorf("src FIEMAP calls for bin/tool = %d, want 1", got)
	}

	// Verify dry-run does not invoke dedupeFile.
	dedupeCalls = 0
	stDry, err := run(config{
		hostStore:          hostStore,
		incusContainersDir: containersDir,
		minSize:            4096,
		dryRun:             true,
	}, mockOps, &logBuf)
	if err != nil {
		t.Fatalf("dry-run returned error: %v", err)
	}
	if dedupeCalls != 0 {
		t.Errorf("dry-run called dedupeFile %d times, want 0", dedupeCalls)
	}
	if stDry.bytesDeduped != wantBytes {
		t.Errorf("dry-run bytesDeduped = %d, want %d", stDry.bytesDeduped, wantBytes)
	}
}

func TestDedupeRootsSameInodeAndAlreadySharedCounts(t *testing.T) {
	tmp := t.TempDir()
	storeA := filepath.Join(tmp, "store-a")
	storeB := filepath.Join(tmp, "store-b")

	pkg := validHashA + "-hardlink"
	srcFile := filepath.Join(storeA, pkg, "file")
	dstFile := filepath.Join(storeB, pkg, "file")
	writeFileSized(t, srcFile, 'h', 4096)
	if err := os.MkdirAll(filepath.Dir(dstFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(srcFile, dstFile); err != nil {
		t.Fatal(err)
	}

	fdA, err := openDirStrict(storeA)
	if err != nil {
		t.Fatal(err)
	}
	fdB, err := openDirStrict(storeB)
	if err != nil {
		_ = syscall.Close(fdA)
		t.Fatal(err)
	}
	roots := []*storeRoot{
		{name: "a", isHost: true, fd: fdA},
		{name: "b", isHost: false, fd: fdB},
	}
	defer closeStoreRoots(roots)

	d := &deduper{
		cfg: config{minSize: 4096},
		op: ops{
			dedupeFile: func(srcFD, dstFD int, size int64) (dedupeResult, error) {
				t.Fatalf("dedupeFile should not be called for same inode")
				return dedupeResult{}, nil
			},
		},
	}
	if err := d.dedupeRoots(roots); err != nil {
		t.Fatalf("dedupeRoots returned error: %v", err)
	}
	if d.st.filesScanned != 1 || d.st.filesAlreadyShared != 1 || d.st.filesDeduped != 0 {
		t.Errorf("unexpected stats for same-inode pair: %+v", d.st)
	}
}

func TestRunErrorHandling(t *testing.T) {
	tmp := t.TempDir()
	hostStore := filepath.Join(tmp, "host-store")
	containersDir := filepath.Join(tmp, "containers")
	guestStore := filepath.Join(containersDir, "user-1000_alpha", "rootfs", "nix", "store")

	pkg := validHashA + "-pkg"
	writeFileSized(t, filepath.Join(hostStore, pkg, "file"), 'x', 4096)
	writeFileSized(t, filepath.Join(guestStore, pkg, "file"), 'x', 4096)

	// Missing containers directory is non-fatal (0 containers).
	stMissing, err := run(config{
		hostStore:          hostStore,
		incusContainersDir: filepath.Join(tmp, "does-not-exist"),
		minSize:            4096,
	}, defaultOps(), &bytes.Buffer{})
	if err != nil {
		t.Fatalf("expected missing containers dir to succeed, got %v", err)
	}
	if stMissing.stores != 1 {
		t.Errorf("stores = %d, want 1", stMissing.stores)
	}

	// Differing file content is skipped, not fatal.
	stDiff, err := run(config{
		hostStore:          hostStore,
		incusContainersDir: containersDir,
		minSize:            4096,
	}, ops{
		dedupeFile: func(srcFD, dstFD int, size int64) (dedupeResult, error) {
			return dedupeResult{differs: true}, nil
		},
	}, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("expected differing file to be non-fatal, got %v", err)
	}
	if stDiff.filesSkipped != 1 || stDiff.filesDeduped != 0 {
		t.Errorf("unexpected stats for differing file: %+v", stDiff)
	}

	// EOPNOTSUPP / EPERM / EROFS must fail fast.
	for _, fatalErr := range []syscall.Errno{syscall.EOPNOTSUPP, syscall.EPERM, syscall.EROFS} {
		_, err := run(config{
			hostStore:          hostStore,
			incusContainersDir: containersDir,
			minSize:            4096,
		}, ops{
			dedupeFile: func(srcFD, dstFD int, size int64) (dedupeResult, error) {
				return dedupeResult{}, fatalErr
			},
		}, &bytes.Buffer{})
		if !errors.Is(err, fatalErr) {
			t.Errorf("expected fatal error %v, got %v", fatalErr, err)
		}
	}
}
