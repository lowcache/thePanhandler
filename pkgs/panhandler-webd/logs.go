package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// LogEntry is one journal record as streamed to the UI.
type LogEntry struct {
	Unit      string `json:"unit"`
	Timestamp string `json:"timestamp"`
	Priority  string `json:"priority"`
	Message   string `json:"message"`
}

// Logs follows a fixed unit list with journalctl; streams are capped (1 GB Pi, 64M unit limit).
type Logs struct {
	Journalctl string
	Units      []string
	slots      chan struct{}
}

var unitName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9@._-]*$`)

var priorities = []string{"emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"}

func NewLogs(journalctl string, units []string, maxStreams int) (*Logs, error) {
	l := &Logs{Journalctl: journalctl, slots: make(chan struct{}, maxStreams)}
	for _, u := range units {
		if u == "" {
			continue
		}
		if !unitName.MatchString(u) {
			return nil, fmt.Errorf("invalid unit name %q", u)
		}
		l.Units = append(l.Units, u)
	}
	return l, nil
}

// parseJournal turns `journalctl -o json` lines into entries. MESSAGE is a byte array when not UTF-8.
func parseJournal(line []byte) (LogEntry, bool) {
	var rec struct {
		Unit     string          `json:"_SYSTEMD_UNIT"`
		Ident    string          `json:"SYSLOG_IDENTIFIER"`
		Realtime string          `json:"__REALTIME_TIMESTAMP"`
		Priority string          `json:"PRIORITY"`
		Message  json.RawMessage `json:"MESSAGE"`
	}
	if json.Unmarshal(line, &rec) != nil {
		return LogEntry{}, false
	}
	var msg string
	if json.Unmarshal(rec.Message, &msg) != nil {
		var raw []byte
		if json.Unmarshal(rec.Message, &raw) != nil {
			return LogEntry{}, false
		}
		msg = string(raw)
	}
	e := LogEntry{Unit: strings.TrimSuffix(rec.Unit, ".service"), Message: cleanLine(msg, 2000), Priority: "info"}
	if e.Unit == "" {
		e.Unit = rec.Ident
	}
	if us, err := strconv.ParseInt(rec.Realtime, 10, 64); err == nil {
		e.Timestamp = time.UnixMicro(us).UTC().Format(time.RFC3339)
	}
	if p, err := strconv.Atoi(rec.Priority); err == nil && p >= 0 && p < len(priorities) {
		e.Priority = priorities[p]
	}
	return e, true
}

// cleanLine drops control characters (ANSI escapes from hostile SSIDs/hostnames) and caps length.
func cleanLine(s string, max int) string {
	var b strings.Builder
	for _, r := range strings.ToValidUTF8(s, "�") {
		if b.Len() >= max {
			break
		}
		if r == '\t' || (r >= 0x20 && r != 0x7f && (r < 0x80 || r > 0x9f)) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func (l *Logs) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok || len(l.Units) == 0 {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "log streaming unavailable"})
		return
	}
	select {
	case l.slots <- struct{}{}:
		defer func() { <-l.slots }()
	default:
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "too many log viewers open"})
		return
	}
	args := []string{"--follow", "--output=json", "--lines=200", "--no-pager"}
	for _, u := range l.Units {
		args = append(args, "--unit="+u)
	}
	ctx, cancel := context.WithCancel(r.Context())
	cmd := exec.CommandContext(ctx, l.Journalctl, args...)
	out, err := cmd.StdoutPipe()
	if err == nil {
		err = cmd.Start()
	}
	if err != nil {
		cancel()
		writeErr(w, err)
		return
	}
	defer cmd.Wait()
	defer cancel() // runs first: journalctl -f never exits on its own

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	lines := make(chan []byte)
	go func() {
		defer close(lines)
		rd := bufio.NewReaderSize(out, 64*1024)
		for {
			line, err := rd.ReadBytes('\n')
			if len(line) > 0 && len(line) <= 256*1024 {
				select {
				case lines <- line:
				case <-ctx.Done():
					return
				}
			}
			if err != nil {
				if err != io.EOF {
					log.Printf("logs: %v", err)
				}
				return
			}
		}
	}()
	keepalive := time.NewTicker(25 * time.Second)
	defer keepalive.Stop()
	enc := json.NewEncoder(w)
	for {
		select {
		case <-ctx.Done():
			return
		case <-keepalive.C:
			if _, err := io.WriteString(w, ": keepalive\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case line, ok := <-lines:
			if !ok {
				return
			}
			e, ok := parseJournal(line)
			if !ok {
				continue
			}
			io.WriteString(w, "event: log\ndata: ")
			if err := enc.Encode(e); err != nil { // Encode ends the data line with '\n'.
				return
			}
			io.WriteString(w, "\n")
			flusher.Flush()
		}
	}
}
