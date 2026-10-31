package main

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func writeWAV(t *testing.T, format, bits uint16, payload []byte) string {
	t.Helper()
	block := uint16(bits / 8)
	fmtChunk := make([]byte, 16)
	binary.LittleEndian.PutUint16(fmtChunk[0:2], format)
	binary.LittleEndian.PutUint16(fmtChunk[2:4], 1)
	binary.LittleEndian.PutUint32(fmtChunk[4:8], 8000)
	binary.LittleEndian.PutUint32(fmtChunk[8:12], 8000*uint32(block))
	binary.LittleEndian.PutUint16(fmtChunk[12:14], block)
	binary.LittleEndian.PutUint16(fmtChunk[14:16], bits)
	data := make([]byte, 8+len(payload))
	copy(data[0:4], "data")
	binary.LittleEndian.PutUint32(data[4:8], uint32(len(payload)))
	copy(data[8:], payload)
	body := append([]byte("WAVEfmt "), byte(16), 0, 0, 0)
	body = append(body, fmtChunk...)
	body = append(body, data...)
	riff := make([]byte, 8)
	copy(riff[0:4], "RIFF")
	binary.LittleEndian.PutUint32(riff[4:8], uint32(len(body)))
	path := filepath.Join(t.TempDir(), "t.wav")
	if err := os.WriteFile(path, append(riff, body...), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestWavPeak(t *testing.T) {
	pcm16 := []byte{0xe8, 0x03, 0x30, 0xf8} // 1000, -2000
	p, err := wavPeak(writeWAV(t, 1, 16, pcm16))
	if err != nil || p != 2000 {
		t.Fatalf("pcm16 peak=%d err=%v", p, err)
	}
	pcm8 := []byte{0xff, 0x80, 0x01} // -1, -128, 1
	p, err = wavPeak(writeWAV(t, 1, 8, pcm8))
	if err != nil || p != 128 {
		t.Fatalf("pcm8 peak=%d err=%v", p, err)
	}
	sample := int32(-300000)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(sample))
	p, err = wavPeak(writeWAV(t, 1, 32, buf))
	if err != nil || p != 300000 {
		t.Fatalf("pcm32 peak=%d err=%v", p, err)
	}
	if _, err = wavPeak(writeWAV(t, 3, 32, buf)); err == nil {
		t.Fatal("float должен быть ошибкой")
	}
	if _, err = wavPeak(writeWAV(t, 1, 24, []byte{1, 2, 3})); err == nil {
		t.Fatal("24 бита должны быть ошибкой")
	}
	empty := writeWAV(t, 1, 16, nil)
	p, err = wavPeak(empty)
	if err != nil || p != 0 {
		t.Fatalf("пусто peak=%d err=%v", p, err)
	}
	odd := writeWAV(t, 1, 16, []byte{0x2c, 0x01, 0xff}) // 300 и хвостовой байт
	p, err = wavPeak(odd)
	if err != nil || p != 300 {
		t.Fatalf("хвост peak=%d err=%v", p, err)
	}
}
