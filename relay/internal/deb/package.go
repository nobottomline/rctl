package deb

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/url"
	"path"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/ulikunitz/xz"
	"github.com/ulikunitz/xz/lzma"
)

const (
	MaxPackageBytes      = 256 << 20
	maxArchiveEntryBytes = 512 << 20
	maxArchiveBytes      = 1 << 30
	maxArchiveEntries    = 100_000
	relayConfigPath      = "var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist"
)

var arMagic = []byte("!<arch>\n")

type Info struct {
	Package      string
	Version      string
	Architecture string
	DataFormat   string
}

type Personalization struct {
	RelayURL   string
	Token      string
	DeviceName string
}

type member struct {
	header [60]byte
	name   string
	data   []byte
}

// Personalize validates a public rctl package and returns a copy containing one
// enrollment configuration. It does not execute package scripts or invoke dpkg.
func Personalize(publicPackage []byte, values Personalization) ([]byte, Info, error) {
	if len(publicPackage) == 0 || len(publicPackage) > MaxPackageBytes {
		return nil, Info{}, fmt.Errorf("package size must be between 1 and %d bytes", MaxPackageBytes)
	}
	if err := values.Validate(); err != nil {
		return nil, Info{}, err
	}
	members, err := parseAR(publicPackage)
	if err != nil {
		return nil, Info{}, err
	}
	info, dataIndex, err := inspect(members)
	if err != nil {
		return nil, Info{}, err
	}
	plist, err := renderRelayPlist(values)
	if err != nil {
		return nil, Info{}, err
	}
	data, err := appendTarFile(members[dataIndex].name, members[dataIndex].data, relayConfigPath, plist)
	if err != nil {
		return nil, Info{}, fmt.Errorf("personalize data archive: %w", err)
	}
	members[dataIndex].data = data
	result, err := writeAR(members)
	if err != nil {
		return nil, Info{}, err
	}
	if len(result) > MaxPackageBytes {
		return nil, Info{}, errors.New("personalized package exceeds the package size limit")
	}
	return result, info, nil
}

func Inspect(publicPackage []byte) (Info, error) {
	if len(publicPackage) == 0 || len(publicPackage) > MaxPackageBytes {
		return Info{}, fmt.Errorf("package size must be between 1 and %d bytes", MaxPackageBytes)
	}
	members, err := parseAR(publicPackage)
	if err != nil {
		return Info{}, err
	}
	info, _, err := inspect(members)
	return info, err
}

func (p Personalization) Validate() error {
	u, err := url.Parse(p.RelayURL)
	if err != nil || u.Scheme != "wss" || u.Host == "" || u.User != nil || u.Fragment != "" {
		return errors.New("relay URL must be an absolute wss URL without credentials or fragment")
	}
	if u.Path != "/device" || u.RawQuery != "" {
		return errors.New("relay URL must use the canonical /device endpoint")
	}
	if len(p.Token) < 32 || len(p.Token) > 512 || strings.ContainsAny(p.Token, "\x00\r\n") {
		return errors.New("enrollment token has an invalid length or character")
	}
	name := strings.TrimSpace(p.DeviceName)
	if name == "" || !utf8.ValidString(name) || utf8.RuneCountInString(name) > 80 || strings.ContainsAny(name, "\x00\r\n") {
		return errors.New("device name must contain 1 to 80 valid characters on one line")
	}
	return nil
}

func inspect(members []member) (Info, int, error) {
	if len(members) != 3 || members[0].name != "debian-binary" || string(members[0].data) != "2.0\n" {
		return Info{}, 0, errors.New("unsupported Debian package envelope")
	}
	controlIndex, dataIndex := -1, -1
	for i, item := range members[1:] {
		i++
		switch {
		case strings.HasPrefix(item.name, "control.tar"):
			if controlIndex >= 0 {
				return Info{}, 0, errors.New("duplicate control archive")
			}
			controlIndex = i
		case strings.HasPrefix(item.name, "data.tar"):
			if dataIndex >= 0 {
				return Info{}, 0, errors.New("duplicate data archive")
			}
			dataIndex = i
		}
	}
	if controlIndex < 0 || dataIndex < 0 {
		return Info{}, 0, errors.New("package is missing control or data archive")
	}
	fields, err := readControl(members[controlIndex].name, members[controlIndex].data)
	if err != nil {
		return Info{}, 0, err
	}
	info := Info{Package: fields["Package"], Version: fields["Version"], Architecture: fields["Architecture"], DataFormat: members[dataIndex].name}
	if info.Package != "com.greatlove.rctl" || info.Version == "" || info.Architecture != "iphoneos-arm" {
		return Info{}, 0, errors.New("base package is not a supported public rctl package")
	}
	found, err := tarContains(members[dataIndex].name, members[dataIndex].data, relayConfigPath)
	if err != nil {
		return Info{}, 0, fmt.Errorf("inspect data archive: %w", err)
	}
	if found {
		return Info{}, 0, errors.New("base package already contains relay configuration")
	}
	return info, dataIndex, nil
}

func parseAR(raw []byte) ([]member, error) {
	if len(raw) < len(arMagic) || !bytes.Equal(raw[:len(arMagic)], arMagic) {
		return nil, errors.New("invalid ar package header")
	}
	offset := len(arMagic)
	items := make([]member, 0, 3)
	for offset < len(raw) {
		if len(raw)-offset < 60 {
			return nil, errors.New("truncated ar member header")
		}
		var header [60]byte
		copy(header[:], raw[offset:offset+60])
		offset += 60
		if string(header[58:60]) != "`\n" {
			return nil, errors.New("invalid ar member trailer")
		}
		name := strings.TrimSpace(string(header[0:16]))
		name = strings.TrimSuffix(name, "/")
		if name == "" || strings.HasPrefix(name, "#1/") || strings.ContainsAny(name, "\\\x00") {
			return nil, errors.New("unsupported ar member name")
		}
		size, err := strconv.ParseInt(strings.TrimSpace(string(header[48:58])), 10, 64)
		if err != nil || size < 0 || size > MaxPackageBytes || size > int64(len(raw)-offset) {
			return nil, errors.New("invalid ar member size")
		}
		data := append([]byte(nil), raw[offset:offset+int(size)]...)
		offset += int(size)
		if size%2 != 0 {
			if offset >= len(raw) || raw[offset] != '\n' {
				return nil, errors.New("invalid ar member padding")
			}
			offset++
		}
		items = append(items, member{header: header, name: name, data: data})
		if len(items) > 16 {
			return nil, errors.New("too many ar members")
		}
	}
	return items, nil
}

func writeAR(items []member) ([]byte, error) {
	var out bytes.Buffer
	out.Write(arMagic)
	for _, item := range items {
		if len(item.data) > MaxPackageBytes {
			return nil, errors.New("ar member exceeds size limit")
		}
		header := item.header
		size := fmt.Sprintf("%-10d", len(item.data))
		if len(size) != 10 {
			return nil, errors.New("ar member size cannot be encoded")
		}
		copy(header[48:58], size)
		out.Write(header[:])
		out.Write(item.data)
		if len(item.data)%2 != 0 {
			out.WriteByte('\n')
		}
	}
	return out.Bytes(), nil
}

func readControl(name string, data []byte) (map[string]string, error) {
	reader, closeReader, err := compressedReader(name, data)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	t := tar.NewReader(reader)
	for count := 0; count < maxArchiveEntries; count++ {
		header, err := t.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read control archive: %w", err)
		}
		clean, err := cleanTarName(header.Name)
		if err != nil {
			return nil, err
		}
		if clean != "control" || !header.FileInfo().Mode().IsRegular() {
			continue
		}
		if header.Size < 0 || header.Size > 1<<20 {
			return nil, errors.New("control metadata exceeds size limit")
		}
		raw, err := io.ReadAll(io.LimitReader(t, header.Size+1))
		if err != nil || int64(len(raw)) != header.Size {
			return nil, errors.New("cannot read package control metadata")
		}
		fields := make(map[string]string)
		for _, line := range strings.Split(string(raw), "\n") {
			key, value, ok := strings.Cut(line, ":")
			if ok && key != "" && !strings.HasPrefix(line, " ") {
				fields[key] = strings.TrimSpace(value)
			}
		}
		return fields, nil
	}
	return nil, errors.New("package control metadata is missing")
}

func tarContains(name string, data []byte, wanted string) (bool, error) {
	reader, closeReader, err := compressedReader(name, data)
	if err != nil {
		return false, err
	}
	defer closeReader()
	t := tar.NewReader(reader)
	var total int64
	for count := 0; count < maxArchiveEntries; count++ {
		header, err := t.Next()
		if errors.Is(err, io.EOF) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		clean, err := cleanTarName(header.Name)
		if err != nil {
			return false, err
		}
		if header.Size < 0 || header.Size > maxArchiveEntryBytes {
			return false, errors.New("archive entry exceeds size limit")
		}
		total += header.Size
		if total > maxArchiveBytes {
			return false, errors.New("archive exceeds uncompressed size limit")
		}
		if clean == wanted {
			return true, nil
		}
	}
	return false, errors.New("archive has too many entries")
}

func appendTarFile(archiveName string, data []byte, fileName string, content []byte) ([]byte, error) {
	reader, closeReader, err := compressedReader(archiveName, data)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	var compressed bytes.Buffer
	writer, closeWriter, err := compressedWriter(archiveName, &compressed)
	if err != nil {
		return nil, err
	}
	tw := tar.NewWriter(writer)
	tr := tar.NewReader(reader)
	directories := make(map[string]bool)
	var total int64
	count := 0
	for ; count < maxArchiveEntries; count++ {
		header, nextErr := tr.Next()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			return nil, nextErr
		}
		clean, err := cleanTarName(header.Name)
		if err != nil {
			return nil, err
		}
		if clean == fileName {
			return nil, errors.New("relay configuration already exists")
		}
		if header.Size < 0 || header.Size > maxArchiveEntryBytes {
			return nil, errors.New("archive entry exceeds size limit")
		}
		total += header.Size
		if total > maxArchiveBytes {
			return nil, errors.New("archive exceeds uncompressed size limit")
		}
		if header.Typeflag == tar.TypeDir {
			directories[strings.TrimSuffix(clean, "/")] = true
		}
		cloned := *header
		if err := tw.WriteHeader(&cloned); err != nil {
			return nil, err
		}
		if _, err := io.CopyN(tw, tr, header.Size); err != nil {
			return nil, err
		}
	}
	if count == maxArchiveEntries {
		return nil, errors.New("archive has too many entries")
	}
	for _, directory := range parentDirectories(fileName) {
		if directories[directory] {
			continue
		}
		if err := tw.WriteHeader(&tar.Header{Name: directory + "/", Typeflag: tar.TypeDir, Mode: 0o755, Uid: 0, Gid: 0}); err != nil {
			return nil, err
		}
	}
	if err := tw.WriteHeader(&tar.Header{Name: fileName, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(content)), Uid: 0, Gid: 0}); err != nil {
		return nil, err
	}
	if _, err := tw.Write(content); err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := closeWriter(); err != nil {
		return nil, err
	}
	return compressed.Bytes(), nil
}

func compressedReader(name string, data []byte) (io.Reader, func() error, error) {
	source := bytes.NewReader(data)
	switch {
	case strings.HasSuffix(name, ".tar"):
		return source, func() error { return nil }, nil
	case strings.HasSuffix(name, ".tar.gz"):
		r, err := gzip.NewReader(source)
		if err != nil {
			return nil, nil, err
		}
		return r, r.Close, nil
	case strings.HasSuffix(name, ".tar.lzma"):
		r, err := lzma.NewReader(source)
		return r, func() error { return nil }, err
	case strings.HasSuffix(name, ".tar.xz"):
		r, err := xz.NewReader(source)
		return r, func() error { return nil }, err
	default:
		return nil, nil, fmt.Errorf("unsupported archive compression %q", name)
	}
}

func compressedWriter(name string, destination io.Writer) (io.Writer, func() error, error) {
	switch {
	case strings.HasSuffix(name, ".tar"):
		return destination, func() error { return nil }, nil
	case strings.HasSuffix(name, ".tar.gz"):
		w := gzip.NewWriter(destination)
		return w, w.Close, nil
	case strings.HasSuffix(name, ".tar.lzma"):
		w, err := lzma.NewWriter(destination)
		if err != nil {
			return nil, nil, err
		}
		return w, w.Close, nil
	case strings.HasSuffix(name, ".tar.xz"):
		w, err := xz.NewWriter(destination)
		if err != nil {
			return nil, nil, err
		}
		return w, w.Close, nil
	default:
		return nil, nil, fmt.Errorf("unsupported archive compression %q", name)
	}
}

func cleanTarName(name string) (string, error) {
	if name == "." || name == "./" {
		return ".", nil
	}
	name = strings.TrimPrefix(name, "./")
	clean := path.Clean(name)
	if clean == "." || strings.HasPrefix(name, "/") || clean == ".." || strings.HasPrefix(clean, "../") || strings.ContainsRune(clean, '\x00') {
		return "", fmt.Errorf("unsafe archive path %q", name)
	}
	return clean, nil
}

func parentDirectories(name string) []string {
	parts := strings.Split(path.Dir(name), "/")
	out := make([]string, 0, len(parts))
	for i := range parts {
		out = append(out, strings.Join(parts[:i+1], "/"))
	}
	return out
}

func renderRelayPlist(values Personalization) ([]byte, error) {
	escape := func(value string) string {
		var out bytes.Buffer
		_ = xml.EscapeText(&out, []byte(value))
		return out.String()
	}
	return []byte(fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Enabled</key>
	<true/>
	<key>DeviceName</key>
	<string>%s</string>
	<key>Relays</key>
	<array>
		<dict>
			<key>Enabled</key>
			<true/>
			<key>RelayURL</key>
			<string>%s</string>
			<key>EnrollToken</key>
			<string>%s</string>
		</dict>
	</array>
</dict>
</plist>
`, escape(strings.TrimSpace(values.DeviceName)), escape(values.RelayURL), escape(values.Token))), nil
}
