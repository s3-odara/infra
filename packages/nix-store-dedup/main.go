//go:build linux

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"unsafe"
)

const (
	// Linux openat2 syscall number (common across architectures).
	sysOpenat2 = 437

	// openat2 resolve flags (include/uapi/linux/openat2.h).
	resolveNoXdev       = 0x01
	resolveNoMagiclinks = 0x02
	resolveNoSymlinks   = 0x04
	resolveBeneath      = 0x08

	// FIDEDUPERANGE ioctl (include/uapi/linux/fs.h).
	ioctlFiDedupeRange = 0xC0189436

	fileDedupeRangeSame    = 0
	fileDedupeRangeDiffers = 1

	// Kernel caps single FIDEDUPERANGE calls at 16 MiB.
	dedupeChunkSize = 16 * 1024 * 1024

	// FS_IOC_FIEMAP ioctl (include/uapi/linux/fiemap.h).
	ioctlFiemap = 0xC020660B

	fiemapExtentLast       = 0x00000001
	fiemapExtentUnknown    = 0x00000002
	fiemapExtentDelalloc   = 0x00000004
	fiemapExtentDataInline = 0x00000200

	fiemapBatchSize  = 64
	fiemapMaxExtents = 1024
)

type openHow struct {
	Flags   uint64
	Mode    uint64
	Resolve uint64
}

type fileDedupeRangeInfo struct {
	DestFD       int64
	DestOffset   uint64
	BytesDeduped uint64
	Status       int32
	Reserved     uint32
}

type fileDedupeRangeSingle struct {
	SrcOffset uint64
	SrcLength uint64
	DestCount uint16
	Reserved1 uint16
	Reserved2 uint32
	Info      fileDedupeRangeInfo
}

type fiemapHeader struct {
	Start         uint64
	Length        uint64
	Flags         uint32
	MappedExtents uint32
	ExtentCount   uint32
	Reserved      uint32
}

type fiemapExtent struct {
	Logical    uint64
	Physical   uint64
	Length     uint64
	Reserved64 [2]uint64
	Flags      uint32
	Reserved   [3]uint32
}

type fiemapRequest struct {
	Header  fiemapHeader
	Extents [fiemapBatchSize]fiemapExtent
}

type config struct {
	hostStore          string
	incusContainersDir string
	minSize            int64
	dryRun             bool
	verbose            bool
}

type stats struct {
	stores             int
	sharedStorePaths   int
	filesScanned       int
	filesAlreadyShared int
	filesDeduped       int
	filesSkipped       int
	bytesDeduped       uint64
}

type storeRoot struct {
	name   string
	isHost bool
	fd     int
}

type dedupeResult struct {
	bytesDeduped uint64
	differs      bool
}

type ops struct {
	readExtents func(fd int, size uint64) ([]fiemapExtent, bool, error)
	dedupeFile  func(srcFD, dstFD int, size int64) (dedupeResult, error)
}

func defaultOps() ops {
	return ops{
		readExtents: readExtents,
		dedupeFile:  dedupeFileRange,
	}
}

type deduper struct {
	cfg    config
	op     ops
	st     stats
	logOut io.Writer
}

func main() {
	var cfg config
	flag.StringVar(&cfg.hostStore, "host-store", "/nix/store", "Path to the host Nix store")
	flag.StringVar(&cfg.incusContainersDir, "incus-containers-dir", "/var/lib/incus-storage/containers", "Path to the Incus containers storage directory")
	flag.Int64Var(&cfg.minSize, "min-size", 4096, "Minimum regular file size in bytes to deduplicate")
	flag.BoolVar(&cfg.dryRun, "dry-run", false, "Report deduplication candidates without calling FIDEDUPERANGE")
	flag.BoolVar(&cfg.verbose, "verbose", false, "Log skipped files and detailed diagnostics")
	flag.Parse()

	if cfg.minSize < 0 {
		fmt.Fprintf(os.Stderr, "nix-store-dedup: --min-size must be non-negative\n")
		os.Exit(2)
	}

	st, err := run(cfg, defaultOps(), os.Stderr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "nix-store-dedup: %v\n", err)
		os.Exit(1)
	}

	mode := "applied"
	if cfg.dryRun {
		mode = "dry-run"
	}
	fmt.Printf(
		"nix-store-dedup (%s): stores=%d shared_store_paths=%d files_scanned=%d files_already_shared=%d files_deduped=%d bytes_deduped=%d files_skipped=%d\n",
		mode,
		st.stores,
		st.sharedStorePaths,
		st.filesScanned,
		st.filesAlreadyShared,
		st.filesDeduped,
		st.bytesDeduped,
		st.filesSkipped,
	)
}

func run(cfg config, op ops, logOut io.Writer) (stats, error) {
	roots, err := discoverStoreRoots(cfg.hostStore, cfg.incusContainersDir, cfg.verbose, logOut)
	if err != nil {
		return stats{}, err
	}
	defer closeStoreRoots(roots)

	d := &deduper{
		cfg:    cfg,
		op:     op,
		logOut: logOut,
	}
	if err := d.dedupeRoots(roots); err != nil {
		return d.st, err
	}
	return d.st, nil
}

// discoverStoreRoots opens the host store followed by all Incus container
// stores in deterministic sorted order.
func discoverStoreRoots(hostStore, containersDir string, verbose bool, logOut io.Writer) ([]*storeRoot, error) {
	hostFD, err := openDirStrict(hostStore)
	if err != nil {
		return nil, fmt.Errorf("open host store %s: %w", hostStore, err)
	}

	roots := []*storeRoot{
		{
			name:   "host",
			isHost: true,
			fd:     hostFD,
		},
	}

	guestRoots, err := discoverIncusStores(containersDir, verbose, logOut)
	if err != nil {
		closeStoreRoots(roots)
		return nil, err
	}
	return append(roots, guestRoots...), nil
}

func discoverIncusStores(containersDir string, verbose bool, logOut io.Writer) ([]*storeRoot, error) {
	entries, err := os.ReadDir(containersDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read containers dir %s: %w", containersDir, err)
	}

	containerNames := make([]string, 0, len(entries))
	for _, e := range entries {
		containerNames = append(containerNames, e.Name())
	}
	sort.Strings(containerNames)

	roots := make([]*storeRoot, 0, len(containerNames))
	for _, name := range containerNames {
		containerPath := filepath.Join(containersDir, name)
		cFD, err := openDirStrict(containerPath)
		if err != nil {
			if verbose {
				fmt.Fprintf(logOut, "skip container %s: %v\n", name, err)
			}
			continue
		}
		storeFD, err := openat2(cFD, "rootfs/nix/store",
			syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC|syscall.O_NONBLOCK,
			resolveBeneath|resolveNoSymlinks|resolveNoMagiclinks)
		_ = syscall.Close(cFD)
		if err != nil {
			if verbose && !errors.Is(err, syscall.ENOENT) {
				fmt.Fprintf(logOut, "skip container %s store: %v\n", name, err)
			}
			continue
		}
		roots = append(roots, &storeRoot{
			name:   name,
			isHost: false,
			fd:     storeFD,
		})
	}
	return roots, nil
}

func closeStoreRoots(roots []*storeRoot) {
	for _, r := range roots {
		if r.fd >= 0 {
			_ = syscall.Close(r.fd)
			r.fd = -1
		}
	}
}

// dedupeRoots deduplicates matching Nix store paths across an ordered list of
// store roots, using the first holder as the canonical source.
func (d *deduper) dedupeRoots(roots []*storeRoot) error {
	d.st.stores = len(roots)
	if len(roots) < 2 {
		return nil
	}

	entriesByPath := make(map[string][]*storeRoot)
	for _, r := range roots {
		names, err := readDirNames(r.fd)
		if err != nil {
			if r.isHost {
				return fmt.Errorf("read host store %s: %w", d.cfg.hostStore, err)
			}
			d.logf("skip store %s: %v\n", r.name, err)
			continue
		}
		for _, name := range names {
			if !isStoreEntryName(name) {
				continue
			}
			entriesByPath[name] = append(entriesByPath[name], r)
		}
	}

	sharedPaths := make([]string, 0)
	for name, holders := range entriesByPath {
		if len(holders) >= 2 {
			sharedPaths = append(sharedPaths, name)
		}
	}
	sort.Strings(sharedPaths)
	d.st.sharedStorePaths = len(sharedPaths)

	for _, storePath := range sharedPaths {
		holders := entriesByPath[storePath]
		if err := d.dedupeEntry(holders[0].fd, storePath, storePath, holders[0], holders[1:]); err != nil {
			return err
		}
	}

	return nil
}

func (d *deduper) dedupeEntry(parentFD int, name, relPath string, srcRoot *storeRoot, dstRoots []*storeRoot) error {
	fd, err := openEntryStrict(parentFD, name)
	if err != nil {
		d.st.filesSkipped++
		d.logf("skip %s/%s: %v\n", srcRoot.name, relPath, err)
		return nil
	}
	defer syscall.Close(fd)

	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		d.st.filesSkipped++
		return nil
	}

	switch st.Mode & syscall.S_IFMT {
	case syscall.S_IFREG:
		return d.dedupeRegularFile(fd, &st, relPath, srcRoot, dstRoots)
	case syscall.S_IFDIR:
		names, err := readDirNames(fd)
		if err != nil {
			d.st.filesSkipped++
			d.logf("skip dir %s/%s: %v\n", srcRoot.name, relPath, err)
			return nil
		}
		sort.Strings(names)
		for _, child := range names {
			if err := d.dedupeEntry(fd, child, path.Join(relPath, child), srcRoot, dstRoots); err != nil {
				return err
			}
		}
		return nil
	default:
		return nil
	}
}

func (d *deduper) dedupeRegularFile(
	srcFD int,
	srcStat *syscall.Stat_t,
	relPath string,
	srcRoot *storeRoot,
	dstRoots []*storeRoot,
) error {
	if srcStat.Size < d.cfg.minSize {
		return nil
	}

	var (
		srcExtents   []fiemapExtent
		srcExtentsOK bool
		srcQueried   bool
	)

	getSrcExtents := func() ([]fiemapExtent, bool) {
		if srcQueried {
			return srcExtents, srcExtentsOK
		}
		srcQueried = true
		if d.op.readExtents == nil {
			return nil, false
		}
		extents, ok, err := d.op.readExtents(srcFD, uint64(srcStat.Size))
		if err != nil || !ok {
			return nil, false
		}
		srcExtents = extents
		srcExtentsOK = true
		return srcExtents, true
	}

	for _, dstRoot := range dstRoots {
		dstFD, err := openEntryStrict(dstRoot.fd, relPath)
		if err != nil {
			d.st.filesSkipped++
			d.logf("skip %s/%s: %v\n", dstRoot.name, relPath, err)
			continue
		}

		err = d.dedupePair(srcFD, srcStat, dstFD, srcRoot.name, dstRoot.name, relPath, getSrcExtents)
		_ = syscall.Close(dstFD)
		if err != nil {
			return err
		}
	}

	return nil
}

func (d *deduper) dedupePair(
	srcFD int,
	srcStat *syscall.Stat_t,
	dstFD int,
	srcName, dstName, relPath string,
	getSrcExtents func() ([]fiemapExtent, bool),
) error {
	var dstStat syscall.Stat_t
	if err := syscall.Fstat(dstFD, &dstStat); err != nil {
		d.st.filesSkipped++
		return nil
	}

	if (dstStat.Mode & syscall.S_IFMT) != syscall.S_IFREG {
		d.st.filesSkipped++
		return nil
	}
	if dstStat.Size != srcStat.Size {
		d.st.filesSkipped++
		return nil
	}

	d.st.filesScanned++

	if dstStat.Dev == srcStat.Dev && dstStat.Ino == srcStat.Ino {
		d.st.filesAlreadyShared++
		return nil
	}

	if srcExtents, ok := getSrcExtents(); ok && d.op.readExtents != nil {
		dstExtents, dstOK, err := d.op.readExtents(dstFD, uint64(srcStat.Size))
		if err == nil && dstOK && extentsEqual(srcExtents, dstExtents) {
			d.st.filesAlreadyShared++
			return nil
		}
	}

	if d.cfg.dryRun {
		d.st.filesDeduped++
		d.st.bytesDeduped += uint64(srcStat.Size)
		return nil
	}

	res, err := d.op.dedupeFile(srcFD, dstFD, srcStat.Size)
	if err != nil {
		if isFatalDedupeError(err) {
			return fmt.Errorf("dedupe %s/%s -> %s/%s: %w", srcName, relPath, dstName, relPath, err)
		}
		d.st.filesSkipped++
		d.logf("skip dedupe %s/%s -> %s/%s: %v\n", srcName, relPath, dstName, relPath, err)
		return nil
	}
	if res.differs {
		d.st.filesSkipped++
		d.logf("skip differing %s/%s -> %s/%s\n", srcName, relPath, dstName, relPath)
		return nil
	}
	if res.bytesDeduped > 0 {
		d.st.filesDeduped++
		d.st.bytesDeduped += res.bytesDeduped
	}
	return nil
}

func (d *deduper) logf(format string, args ...any) {
	if d.cfg.verbose && d.logOut != nil {
		fmt.Fprintf(d.logOut, format, args...)
	}
}

func isFatalDedupeError(err error) bool {
	return errors.Is(err, syscall.EOPNOTSUPP) ||
		errors.Is(err, syscall.ENOSYS) ||
		errors.Is(err, syscall.EPERM) ||
		errors.Is(err, syscall.EROFS)
}

// isStoreEntryName matches valid Nix store path names (<32 nixbase32>-<name>)
// and excludes lock files, .links, and .chroot directories.
func isStoreEntryName(name string) bool {
	if len(name) <= 33 || name[32] != '-' {
		return false
	}
	if strings.HasSuffix(name, ".lock") || strings.HasSuffix(name, ".chroot") {
		return false
	}
	for i := 0; i < 32; i++ {
		if !isNixBase32(name[i]) {
			return false
		}
	}
	return true
}

func isNixBase32(b byte) bool {
	if b >= '0' && b <= '9' {
		return true
	}
	if b >= 'a' && b <= 'z' {
		switch b {
		case 'e', 'o', 't', 'u':
			return false
		default:
			return true
		}
	}
	return false
}

func openDirStrict(p string) (int, error) {
	return openat2(atFDCwd(), p,
		syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC|syscall.O_NONBLOCK,
		resolveNoSymlinks|resolveNoMagiclinks)
}

func openEntryStrict(dirFD int, relPath string) (int, error) {
	return openat2(dirFD, relPath,
		syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NONBLOCK,
		resolveBeneath|resolveNoSymlinks|resolveNoMagiclinks|resolveNoXdev)
}

func atFDCwd() int {
	return -100
}

func openat2(dirFD int, pathname string, flags uint64, resolve uint64) (int, error) {
	pathPtr, err := syscall.BytePtrFromString(pathname)
	if err != nil {
		return -1, err
	}
	how := openHow{
		Flags:   flags,
		Resolve: resolve,
	}
	for {
		fd, _, errno := syscall.Syscall6(
			sysOpenat2,
			uintptr(dirFD),
			uintptr(unsafe.Pointer(pathPtr)),
			uintptr(unsafe.Pointer(&how)),
			unsafe.Sizeof(how),
			0,
			0,
		)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			return -1, errno
		}
		return int(fd), nil
	}
}

// readDirNames opens an independent directory file description for dirFD and
// reads its entry names without altering or closing dirFD.
func readDirNames(dirFD int) ([]string, error) {
	fd, err := openat2(dirFD, ".",
		syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC|syscall.O_NONBLOCK,
		resolveBeneath|resolveNoSymlinks|resolveNoMagiclinks)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "")
	defer f.Close()

	return f.Readdirnames(-1)
}

func dedupeFileRange(srcFD, dstFD int, size int64) (dedupeResult, error) {
	var total uint64
	var offset uint64
	target := uint64(size)

	for offset < target {
		chunk := target - offset
		if chunk > dedupeChunkSize {
			chunk = dedupeChunkSize
		}

		req := fileDedupeRangeSingle{
			SrcOffset: offset,
			SrcLength: chunk,
			DestCount: 1,
			Info: fileDedupeRangeInfo{
				DestFD:     int64(dstFD),
				DestOffset: offset,
			},
		}

		for {
			_, _, errno := syscall.Syscall(
				syscall.SYS_IOCTL,
				uintptr(srcFD),
				uintptr(ioctlFiDedupeRange),
				uintptr(unsafe.Pointer(&req)),
			)
			if errno == syscall.EINTR {
				continue
			}
			if errno != 0 {
				return dedupeResult{bytesDeduped: total}, errno
			}
			break
		}

		switch {
		case req.Info.Status == fileDedupeRangeDiffers:
			return dedupeResult{bytesDeduped: total, differs: true}, nil
		case req.Info.Status < 0:
			return dedupeResult{bytesDeduped: total}, syscall.Errno(-req.Info.Status)
		case req.Info.Status != fileDedupeRangeSame:
			return dedupeResult{bytesDeduped: total}, fmt.Errorf("unexpected FIDEDUPERANGE status %d", req.Info.Status)
		}

		if req.Info.BytesDeduped == 0 {
			break
		}
		total += req.Info.BytesDeduped
		offset += req.Info.BytesDeduped
	}

	return dedupeResult{bytesDeduped: total}, nil
}

func readExtents(fd int, size uint64) ([]fiemapExtent, bool, error) {
	var all []fiemapExtent
	var start uint64

	for start < size {
		var req fiemapRequest
		req.Header = fiemapHeader{
			Start:       start,
			Length:      size - start,
			ExtentCount: fiemapBatchSize,
		}

		for {
			_, _, errno := syscall.Syscall(
				syscall.SYS_IOCTL,
				uintptr(fd),
				uintptr(ioctlFiemap),
				uintptr(unsafe.Pointer(&req)),
			)
			if errno == syscall.EINTR {
				continue
			}
			if errno != 0 {
				return nil, false, errno
			}
			break
		}

		mapped := int(req.Header.MappedExtents)
		if mapped == 0 {
			break
		}
		if len(all)+mapped > fiemapMaxExtents {
			return nil, false, nil
		}

		all = append(all, req.Extents[:mapped]...)
		last := req.Extents[mapped-1]
		if (last.Flags & fiemapExtentLast) != 0 {
			break
		}
		next := last.Logical + last.Length
		if next <= start {
			return nil, false, nil
		}
		start = next
	}

	return all, true, nil
}

func extentsEqual(a, b []fiemapExtent) bool {
	if len(a) == 0 || len(a) != len(b) {
		return false
	}
	const unstableFlags = fiemapExtentUnknown | fiemapExtentDelalloc | fiemapExtentDataInline
	for i := range a {
		if (a[i].Flags&unstableFlags) != 0 || (b[i].Flags&unstableFlags) != 0 {
			return false
		}
		if a[i].Physical == 0 || b[i].Physical == 0 {
			return false
		}
		if a[i].Logical != b[i].Logical ||
			a[i].Physical != b[i].Physical ||
			a[i].Length != b[i].Length {
			return false
		}
	}
	return true
}
