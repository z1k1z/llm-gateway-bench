// Мок OpenAI-совместимого апстрима. Профиль берется из имени модели,
// свои заголовки гейтвеи не пропускают.
//
//	mock-fast       TTFT 20 мс,  2 мс/токен, 64 токена
//	mock-realistic  TTFT 400 мс, 33 мс/токен, 150 токенов
//
// Отказы через POST /control, каждый N-й запрос.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type profile struct {
	ttft   time.Duration
	inter  time.Duration
	tokens int
}

var profiles = map[string]profile{
	"mock-fast":      {20 * time.Millisecond, 2 * time.Millisecond, 64},
	"mock-realistic": {400 * time.Millisecond, 33 * time.Millisecond, 150},
}

// первым токеном идет mockName, по нему видно, кто ответил при фолбэке
var mockName = func() string {
	if v := os.Getenv("MOCK_NAME"); v != "" {
		return v
	}
	return "mock"
}()

var vocab = strings.Fields(
	"сервер прокси запрос ответ задержка поток токен ключ лимит бюджет " +
		"логи метрика канал модель провайдер кэш очередь отказ повтор маршрут")

type faults struct {
	mu      sync.RWMutex
	mode    string  // none | 429 | 503 | timeout | truncate
	rate    float64 // 0..1
	counter atomic.Uint64
}

func (f *faults) set(mode string, rate float64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.mode, f.rate = mode, rate
	f.counter.Store(0)
}

func (f *faults) get() (string, float64) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.mode, f.rate
}

// rate=0.25 значит каждый четвертый
func (f *faults) hit() (string, bool) {
	mode, rate := f.get()
	if mode == "" || mode == "none" || rate <= 0 {
		return "", false
	}
	n := f.counter.Add(1)
	if rate >= 1 {
		return mode, true
	}
	every := uint64(math.Round(1 / rate))
	if every < 1 {
		every = 1
	}
	return mode, n%every == 0
}

var state faults

// с одинаковым id litellm сваливал все запросы в одну строку SpendLogs
var respSeq atomic.Uint64

func respID() string {
	return fmt.Sprintf("chatcmpl-%s-%d", mockName, respSeq.Add(1))
}

type chatRequest struct {
	Model        string `json:"model"`
	Stream       bool   `json:"stream"`
	StreamOption *struct {
		IncludeUsage bool `json:"include_usage"`
	} `json:"stream_options"`
	Messages []struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
}

func envDur(name string, def time.Duration) time.Duration {
	if v := os.Getenv(name); v != "" {
		if ms, err := strconv.Atoi(v); err == nil {
			return time.Duration(ms) * time.Millisecond
		}
	}
	return def
}

func resolveProfile(model string) profile {
	// имя модели гейтвеи переписывают ("openai/mock-fast" и т.п.)
	for _, name := range []string{"mock-realistic", "mock-fast"} {
		if strings.Contains(model, name) {
			return profiles[name]
		}
	}
	return profiles["mock-fast"]
}

func promptTokens(req *chatRequest) int {
	n := 0
	for _, m := range req.Messages {
		n += len(m.Content) / 4
	}
	if n < 1 {
		n = 1
	}
	return n
}

func writeErr(w http.ResponseWriter, code int, kind, msg string) {
	w.Header().Set("Content-Type", "application/json")
	if code == http.StatusTooManyRequests {
		w.Header().Set("Retry-After", "1")
	}
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{"message": msg, "type": kind, "code": code},
	})
}

func handleChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "invalid_request_error", "only POST")
		return
	}
	var req chatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_request_error", "bad json: "+err.Error())
		return
	}

	if mode, ok := state.hit(); ok {
		switch mode {
		case "429":
			writeErr(w, http.StatusTooManyRequests, "rate_limit_error", "mock: rate limit")
			return
		case "503":
			writeErr(w, http.StatusServiceUnavailable, "api_error", "mock: upstream unavailable")
			return
		case "timeout":
			time.Sleep(envDur("MOCK_TIMEOUT_SLEEP_MS", 30*time.Second))
			writeErr(w, http.StatusGatewayTimeout, "api_error", "mock: slept past your timeout")
			return
		case "truncate":
			streamResponse(w, &req, true)
			return
		}
	}

	if req.Stream {
		streamResponse(w, &req, false)
		return
	}

	p := resolveProfile(req.Model)
	time.Sleep(p.ttft + p.inter*time.Duration(p.tokens))

	words := make([]string, p.tokens)
	for i := range words {
		words[i] = vocab[i%len(vocab)]
	}
	if len(words) > 0 {
		words[0] = mockName
	}
	pt := promptTokens(&req)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":      respID(),
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   req.Model,
		"choices": []any{map[string]any{
			"index":         0,
			"message":       map[string]any{"role": "assistant", "content": strings.Join(words, " ")},
			"finish_reason": "stop",
		}},
		"usage": map[string]any{
			"prompt_tokens":     pt,
			"completion_tokens": p.tokens,
			"total_tokens":      pt + p.tokens,
		},
	})
}

func streamResponse(w http.ResponseWriter, req *chatRequest, truncate bool) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "api_error", "no flusher")
		return
	}
	p := resolveProfile(req.Model)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	time.Sleep(p.ttft)

	cut := p.tokens
	if truncate {
		cut = p.tokens / 2
		if cut < 1 {
			cut = 1
		}
	}

	id := respID()
	send := func(delta map[string]any, finish any) {
		chunk := map[string]any{
			"id":      id,
			"object":  "chat.completion.chunk",
			"created": time.Now().Unix(),
			"model":   req.Model,
			"choices": []any{map[string]any{
				"index": 0, "delta": delta, "finish_reason": finish,
			}},
		}
		b, _ := json.Marshal(chunk)
		fmt.Fprintf(w, "data: %s\n\n", b)
		flusher.Flush()
	}

	send(map[string]any{"role": "assistant", "content": ""}, nil)

	for i := 0; i < cut; i++ {
		if i > 0 {
			time.Sleep(p.inter)
		}
		word := vocab[i%len(vocab)]
		if i == 0 {
			word = mockName
		}
		send(map[string]any{"content": word + " "}, nil)
	}

	if truncate {
		// рвем без finish_reason и [DONE]
		if hj, ok := w.(http.Hijacker); ok {
			if conn, _, err := hj.Hijack(); err == nil {
				_ = conn.Close()
				return
			}
		}
		return
	}

	send(map[string]any{}, "stop")

	// usage всегда, иначе расходы не посчитать
	pt := promptTokens(req)
	usage := map[string]any{
		"id":      id,
		"object":  "chat.completion.chunk",
		"created": time.Now().Unix(),
		"model":   req.Model,
		"choices": []any{},
		"usage": map[string]any{
			"prompt_tokens":     pt,
			"completion_tokens": cut,
			"total_tokens":      pt + cut,
		},
	}
	b, _ := json.Marshal(usage)
	fmt.Fprintf(w, "data: %s\n\n", b)
	fmt.Fprint(w, "data: [DONE]\n\n")
	flusher.Flush()
}

func handleModels(w http.ResponseWriter, _ *http.Request) {
	var list []any
	for name := range profiles {
		list = append(list, map[string]any{
			"id": name, "object": "model", "created": 0, "owned_by": "mock",
		})
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"object": "list", "data": list})
}

func handleControl(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		var body struct {
			Mode string   `json:"mode"`
			Rate *float64 `json:"rate"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid_request_error", err.Error())
			return
		}
		rate := 1.0
		if body.Rate != nil {
			rate = *body.Rate
		}
		switch body.Mode {
		case "", "none", "429", "503", "timeout", "truncate":
		default:
			writeErr(w, http.StatusBadRequest, "invalid_request_error",
				"mode: none|429|503|timeout|truncate")
			return
		}
		state.set(body.Mode, rate)
		log.Printf("control: mode=%q rate=%v", body.Mode, rate)
	}
	mode, rate := state.get()
	if mode == "" {
		mode = "none"
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"mode": mode, "rate": rate})
}

func main() {
	addr := os.Getenv("MOCK_ADDR")
	if addr == "" {
		addr = ":9000"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", handleChat)
	mux.HandleFunc("/v1/models", handleModels)
	mux.HandleFunc("/control", handleControl)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, "ok")
	})
	// чтобы видеть, какой путь гейтвей реально дергает
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("404: %s %s", r.Method, r.URL.Path)
		writeErr(w, http.StatusNotFound, "invalid_request_error",
			"мок не обслуживает "+r.URL.Path+", проверь base_url")
	})

	srv := &http.Server{
		Addr:    addr,
		Handler: mux,
		// без WriteTimeout: realistic и timeout держат соединение долго
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("mock upstream %q на %s, профили: mock-fast, mock-realistic", mockName, addr)
	log.Fatal(srv.ListenAndServe())
}
