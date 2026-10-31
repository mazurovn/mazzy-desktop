// Команда mazzy-wavpeak печатает пик модуля отсчёта в PCM WAV.
// Ноль — пустой файл, не PCM 8/16/32 или любая ошибка чтения.
package main

import (
	"encoding/binary"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Println(0)
		return
	}
	peak, err := wavPeak(os.Args[1])
	if err != nil {
		fmt.Println(0)
		return
	}
	fmt.Println(peak)
}

// wavPeak — максимум |отсчёта| по всем каналам.
// 8 бит читаются как знаковый байт: так же, как прежний разбор array('b').
func wavPeak(path string) (int64, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	samples, width, err := pcmSamples(b)
	if err != nil {
		return 0, err
	}
	n := len(samples) / width * width
	var peak int64
	for i := 0; i < n; i += width {
		var v int64
		switch width {
		case 1:
			v = int64(int8(samples[i]))
		case 2:
			v = int64(int16(binary.LittleEndian.Uint16(samples[i:])))
		case 4:
			v = int64(int32(binary.LittleEndian.Uint32(samples[i:])))
		default:
			return 0, fmt.Errorf("ширина %d", width)
		}
		if v < 0 {
			v = -v
		}
		if v > peak {
			peak = v
		}
	}
	return peak, nil
}

func pcmSamples(b []byte) ([]byte, int, error) {
	if len(b) < 12 || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		return nil, 0, fmt.Errorf("не WAVE")
	}
	var format, bits uint16
	var data []byte
	gotFmt, gotData := false, false
	off := 12
	for off+8 <= len(b) {
		id := string(b[off : off+4])
		sz := int(binary.LittleEndian.Uint32(b[off+4 : off+8]))
		off += 8
		if sz < 0 || off+sz > len(b) {
			return nil, 0, fmt.Errorf("битый блок")
		}
		payload := b[off : off+sz]
		switch id {
		case "fmt ":
			if len(payload) < 16 {
				return nil, 0, fmt.Errorf("короткий fmt")
			}
			format = binary.LittleEndian.Uint16(payload[0:2])
			bits = binary.LittleEndian.Uint16(payload[14:16])
			gotFmt = true
		case "data":
			data = payload
			gotData = true
		}
		off += sz
		if sz%2 == 1 {
			off++
		}
		if gotData {
			break
		}
	}
	if !gotFmt || !gotData {
		return nil, 0, fmt.Errorf("нет fmt или data")
	}
	if format != 1 || (bits != 8 && bits != 16 && bits != 32) {
		return nil, 0, fmt.Errorf("не PCM %d/%d", format, bits)
	}
	return data, int(bits / 8), nil
}
