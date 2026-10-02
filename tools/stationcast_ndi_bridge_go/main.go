package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/ice/v2"
	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v3"
	"github.com/pion/webrtc/v3/pkg/media/samplebuilder"
)

type Config struct {
	Host         string `json:"host"`
	Stream       string `json:"stream"`
	NDIName      string `json:"ndi_name"`
	StandbyImage string `json:"standby_image"`
	EnableLogs   bool   `json:"enable_logs"`
	VerboseLogs  bool   `json:"verbose_logs"`
}

type State struct {
	sync.Mutex
	Status       string   `json:"status"`
	StatusColor  string   `json:"status_color"`
	Host         string   `json:"host"`
	Stream       string   `json:"stream"`
	NDIName      string   `json:"ndi_name"`
	StandbyImage string   `json:"standby_image"`
	Resolution   string   `json:"resolution"`
	FPS          int      `json:"fps"`
	FrameCount   int64    `json:"frame_count"`
	Mode         string   `json:"mode"`
	EnableLogs   bool     `json:"enable_logs"`
	VerboseLogs  bool     `json:"verbose_logs"`
	Logs         []string `json:"logs"`
}

var (
	state = State{
		Status:       "Disconnected",
		StatusColor:  "red",
		Host:         "75.119.149.43",
		Stream:       "field1",
		NDIName:      "Field1StationCast",
		StandbyImage: "smpte_color_bars.webp",
		Resolution:   "1280x720",
		FPS:          0,
		FrameCount:   0,
		Mode:         "Disconnected",
		EnableLogs:   true,
		VerboseLogs:  false, // Off by default in production to save CPU & avoid log spamming
		Logs:         make([]string, 0),
	}
	activeEngine *BridgeEngine
	configFile   = "ndi_bridge_config.json"
)

func addLog(msg string) {
	state.Lock()
	defer state.Unlock()
	if !state.EnableLogs {
		return
	}
	log.Println(msg)
	state.Logs = append(state.Logs, fmt.Sprintf("[%s] %s", time.Now().Format("15:04:05"), msg))
	if len(state.Logs) > 100 {
		state.Logs = state.Logs[1:]
	}
}

func addVerboseLog(msg string) {
	state.Lock()
	enabled := state.EnableLogs && state.VerboseLogs
	state.Unlock()
	if enabled {
		addLog(msg)
	}
}

func loadConfig() {
	if data, err := os.ReadFile(configFile); err == nil {
		var cfg Config
		if err := json.Unmarshal(data, &cfg); err == nil {
			if cfg.Host != "" {
				state.Host = cfg.Host
			}
			if cfg.Stream != "" {
				state.Stream = cfg.Stream
			}
			if cfg.NDIName != "" {
				state.NDIName = cfg.NDIName
			}
			if cfg.StandbyImage != "" {
				state.StandbyImage = cfg.StandbyImage
			}
			state.EnableLogs = cfg.EnableLogs
			state.VerboseLogs = cfg.VerboseLogs
		}
	}
}

func saveConfig() {
	cfg := Config{
		Host:         state.Host,
		Stream:       state.Stream,
		NDIName:      state.NDIName,
		StandbyImage: state.StandbyImage,
		EnableLogs:   state.EnableLogs,
		VerboseLogs:  state.VerboseLogs,
	}
	if data, err := json.MarshalIndent(cfg, "", "  "); err == nil {
		_ = os.WriteFile(configFile, data, 0644)
	}
}

type BridgeEngine struct {
	sync.Mutex
	running    bool
	ndi        *NDIBridge
	peerConn   *webrtc.PeerConnection
	activeSSRC uint32
	stopChan   chan struct{}
}

func NewBridgeEngine() *BridgeEngine {
	return &BridgeEngine{
		stopChan: make(chan struct{}),
	}
}

func (e *BridgeEngine) Start(host, stream, ndiName, standbyImg string) {
	e.Lock()
	if e.running {
		e.Unlock()
		e.Stop()
		e.Lock()
	}
	e.running = true
	e.stopChan = make(chan struct{})
	e.Unlock()

	go e.runLoop(host, stream, ndiName, standbyImg)
}

func (e *BridgeEngine) RequestPLI() {
	e.Lock()
	pc := e.peerConn
	ssrc := e.activeSSRC
	e.Unlock()

	if pc != nil && ssrc != 0 {
		addLog("🚀 Manual Keyframe Request (PLI) sent to stream publisher")
		_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
	} else {
		addLog("⚠️ Cannot send PLI: No active video stream connection")
	}
}

func (e *BridgeEngine) UpdateStandbyImage(path string) {
	e.Lock()
	ndi := e.ndi
	e.Unlock()

	if ndi != nil {
		ndi.SetStandbyImage(path)
	}
}

func (e *BridgeEngine) Stop() {
	e.Lock()
	defer e.Unlock()
	if !e.running {
		return
	}
	e.running = false
	close(e.stopChan)

	if e.peerConn != nil {
		_ = e.peerConn.Close()
		e.peerConn = nil
	}
	if e.ndi != nil {
		e.ndi.Close()
		e.ndi = nil
	}

	state.Lock()
	state.Status = "Disconnected"
	state.StatusColor = "red"
	state.Mode = "Disconnected"
	state.FPS = 0
	state.Unlock()
}

func (e *BridgeEngine) runLoop(host, stream, ndiName, standbyImg string) {
	cleanName := strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(ndiName, "(", ""), ")", ""), " ", ""), "_", "")
	if cleanName == "" {
		cleanName = "Field1StationCast"
	}

	state.Lock()
	state.Status = "Initializing NDI (SMPTE Color Bars)..."
	state.StatusColor = "yellow"
	state.Mode = "Standby (Color Bars)"
	state.Unlock()

	ndiBridge, err := NewNDIBridge(cleanName, standbyImg)
	if err != nil {
		addLog("ERROR: " + err.Error())
		state.Lock()
		state.Status = "NDI Init Failed"
		state.StatusColor = "red"
		state.Mode = "Failed"
		state.Unlock()
		return
	}
	e.ndi = ndiBridge
	addLog(fmt.Sprintf("NDI Stream published as '%s' (Standby Color Bars Active)", cleanName))

	for {
		e.Lock()
		running := e.running
		e.Unlock()
		if !running {
			break
		}

		connected := e.connectAndStream(host, stream)
		if connected {
			addLog("Live media stream finished.")
		}

		e.Lock()
		running = e.running
		e.Unlock()
		if !running {
			break
		}

		addLog("Waiting for stream publisher... Displaying SMPTE Color Bars (Retrying in 500ms)")
		state.Lock()
		state.Status = "Standby (SMPTE Color Bars)"
		state.StatusColor = "yellow"
		state.Mode = "Standby (Color Bars)"
		state.FPS = 30
		state.Unlock()

		select {
		case <-e.stopChan:
			return
		case <-time.After(500 * time.Millisecond):
		}
	}
}

type OMEMessage struct {
	Command    string `json:"command"`
	Code       int    `json:"code,omitempty"`
	ID         int    `json:"id,omitempty"`
	PeerID     int    `json:"peer_id,omitempty"`
	SDP        any    `json:"sdp,omitempty"`
	Candidates []any  `json:"candidates,omitempty"`
}

func (e *BridgeEngine) connectAndStream(host, stream string) bool {
	wsURL := fmt.Sprintf("ws://%s:3333/app/%s", host, stream)
	addLog("Connecting to OME WebSocket: " + wsURL)

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		addLog("WebSocket Dial Error: " + err.Error())
		return false
	}
	defer conn.Close()

	var wsLock sync.Mutex

	addLog("Requesting offer from OME...")
	wsLock.Lock()
	err = conn.WriteJSON(map[string]string{"command": "request_offer"})
	wsLock.Unlock()
	if err != nil {
		addLog("Request offer write error: " + err.Error())
		return false
	}

	var offerMsg OMEMessage
	if err := conn.ReadJSON(&offerMsg); err != nil {
		addLog("Read offer error: " + err.Error())
		return false
	}

	if offerMsg.Code == 404 || offerMsg.Command == "error" {
		addLog(fmt.Sprintf("⚠️ Stream '%s' is not active on OME server yet.", stream))
		return false
	}

	var offerSDPStr string
	if sdpMap, ok := offerMsg.SDP.(map[string]any); ok {
		if s, ok := sdpMap["sdp"].(string); ok {
			offerSDPStr = s
		}
	} else if s, ok := offerMsg.SDP.(string); ok {
		offerSDPStr = s
	}

	if offerSDPStr == "" {
		addLog("ERROR: Invalid offer SDP received")
		return false
	}

	offerMid := "0"
	for _, l := range strings.Split(offerSDPStr, "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "a=mid:") {
			offerMid = strings.TrimPrefix(l, "a=mid:")
			break
		}
	}

	m := &webrtc.MediaEngine{}
	if err := m.RegisterDefaultCodecs(); err != nil {
		addLog("Register default codecs error: " + err.Error())
		return false
	}

	i := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(m, i); err != nil {
		addLog("Register default interceptors error: " + err.Error())
		return false
	}

	se := webrtc.SettingEngine{}
	se.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)

	api := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(i), webrtc.WithSettingEngine(se))
	pc, err := api.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{
			{
				URLs: []string{"stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"},
			},
		},
	})
	if err != nil {
		addLog("Pion PeerConnection error: " + err.Error())
		return false
	}
	e.peerConn = pc

	pc.OnICEConnectionStateChange(func(connectionState webrtc.ICEConnectionState) {
		addLog(fmt.Sprintf("ICE Connection State changed: %s", connectionState.String()))
		if connectionState == webrtc.ICEConnectionStateDisconnected ||
			connectionState == webrtc.ICEConnectionStateFailed ||
			connectionState == webrtc.ICEConnectionStateClosed {
			addLog("⚠️ Connection interrupted (e.g. device rotation/network reset). Initiating fast reconnect...")
			_ = pc.Close()
		}
	})

	// Trickle local ICE candidates to OME over WebSocket as they are gathered
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		candJSON := c.ToJSON()
		candMsg := map[string]any{
			"command": "candidate",
			"id":      offerMsg.ID,
			"peer_id": offerMsg.PeerID,
			"candidates": []map[string]any{
				{
					"candidate":     candJSON.Candidate,
					"sdpMid":        offerMid,
					"sdpMLineIndex": 0,
				},
			},
		}
		wsLock.Lock()
		_ = conn.WriteJSON(candMsg)
		wsLock.Unlock()
	})

	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		addLog("AddTransceiver video error: " + err.Error())
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		addLog("AddTransceiver audio error: " + err.Error())
	}

	doneChan := make(chan struct{})

	pc.OnTrack(func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		addLog(fmt.Sprintf("🎥 TRACK ARRIVED: %s (Codec: %s, SSRC: %d)", track.Kind().String(), track.Codec().MimeType, track.SSRC()))
		if track.Kind() == webrtc.RTPCodecTypeVideo {
			e.Lock()
			e.activeSSRC = uint32(track.SSRC())
			e.Unlock()
			go e.handleVideoTrack(track, pc, doneChan)
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  offerSDPStr,
	}); err != nil {
		addLog("SetRemoteDescription error: " + err.Error())
		return false
	}

	// Add OME's remote candidates
	if offerMsg.Candidates != nil {
		for _, c := range offerMsg.Candidates {
			if cMap, ok := c.(map[string]any); ok {
				if candStr, ok := cMap["candidate"].(string); ok {
					candStr = strings.TrimPrefix(candStr, "a=")
					_ = pc.AddICECandidate(webrtc.ICECandidateInit{
						Candidate: candStr,
						SDPMid:    &offerMid,
					})
				}
			}
		}
	}

	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		addLog("CreateAnswer error: " + err.Error())
		return false
	}

	if err := pc.SetLocalDescription(answer); err != nil {
		addLog("SetLocalDescription error: " + err.Error())
		return false
	}

	// Send answer SDP to OME
	reply := map[string]any{
		"command": "answer",
		"sdp": map[string]string{
			"type": "answer",
			"sdp":  pc.LocalDescription().SDP,
		},
	}
	if offerMsg.ID != 0 {
		reply["id"] = offerMsg.ID
	}
	if offerMsg.PeerID != 0 {
		reply["peer_id"] = offerMsg.PeerID
	}

	wsLock.Lock()
	err = conn.WriteJSON(reply)
	wsLock.Unlock()
	if err != nil {
		addLog("Answer write error: " + err.Error())
		return false
	}

	addLog("CONNECTED via WebSocket! Media streaming -> NDI outputting.")
	state.Lock()
	state.Status = "Streaming Live NDI"
	state.StatusColor = "green"
	state.Mode = "Live Stream"
	state.Unlock()

	<-doneChan
	return true
}

func (e *BridgeEngine) handleVideoTrack(track *webrtc.TrackRemote, pc *webrtc.PeerConnection, doneChan chan struct{}) {
	defer func() {
		if r := recover(); r != nil {
			addLog(fmt.Sprintf("⚠️ Recovered from video decoder pipeline panic: %v", r))
		}
		close(doneChan)
	}()
	addLog(fmt.Sprintf("⚡ Starting VP8 Video Decoder & NDI Pipeline... (SSRC: %d)", track.SSRC()))

	decoder, err := NewVideoDecoder()
	if err != nil {
		addLog("ERROR: Failed to create VP8 Video Decoder: " + err.Error())
		return
	}
	defer decoder.Close()

	// Send periodic PLI keyframe requests on startup to force immediate I-Frame from sender
	go func() {
		for i := 0; i < 10; i++ {
			_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: uint32(track.SSRC())}})
			time.Sleep(300 * time.Millisecond)
		}
	}()

	builder := samplebuilder.New(50, &codecs.VP8Packet{}, track.Codec().ClockRate)
	var totalFrames int64
	var framesInSecond int64
	gotKeyframe := false

	// Stats reporting ticker
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	go func() {
		for range ticker.C {
			e.Lock()
			running := e.running
			e.Unlock()
			if !running {
				return
			}
			currentFPS := atomic.SwapInt64(&framesInSecond, 0)
			state.Lock()
			state.FPS = int(currentFPS)
			state.FrameCount = atomic.LoadInt64(&totalFrames)
			state.Unlock()
		}
	}()

	for {
		e.Lock()
		running := e.running
		e.Unlock()
		if !running {
			break
		}

		pkt, _, err := track.ReadRTP()
		if err != nil {
			addLog("ReadRTP error: " + err.Error())
			break
		}

		builder.Push(pkt)

		for {
			sample := builder.Pop()
			if sample == nil {
				break
			}

			frameData := sample.Data
			if len(frameData) == 0 {
				continue
			}

			// VP8 Keyframe Check: Bit 0 of byte 0 is 0 for keyframes, 1 for inter-frames (P-frames)
			isKeyframe := (frameData[0] & 0x01) == 0

			if !gotKeyframe {
				if !isKeyframe {
					_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: uint32(track.SSRC())}})
					continue
				}
				gotKeyframe = true
			}

			w, h, bgraSlice, stride, err := decoder.Decode(frameData)
			if err != nil || w <= 0 || h <= 0 || len(bgraSlice) == 0 {
				gotKeyframe = false
				_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: uint32(track.SSRC())}})
				continue
			}

			if e.ndi != nil {
				e.ndi.SendVideo(w, h, bgraSlice, stride)
				frameCount := atomic.AddInt64(&totalFrames, 1)
				atomic.AddInt64(&framesInSecond, 1)

				if isKeyframe {
					addVerboseLog(fmt.Sprintf("🔑 Synchronized VP8 Keyframe! Resolution: %dx%d", w, h))
					state.Lock()
					state.Resolution = fmt.Sprintf("%dx%d", w, h)
					state.Unlock()
				}
				if frameCount%120 == 0 || frameCount == 1 {
					addVerboseLog(fmt.Sprintf("🎥 Hardware Rendered %d live video frames to NDI (%dx%d)", frameCount, w, h))
				}
			}
		}
	}
}

// HTTP Web Dashboard
const htmlPage = `<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>StationCast OME to NDI Bridge (Go Edition)</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 20px; }
        .card { background: #1e293b; border-radius: 12px; padding: 24px; max-width: 680px; margin: 0 auto; box-shadow: 0 10px 25px rgba(0,0,0,0.5); }
        h1 { margin-top: 0; font-size: 22px; color: #38bdf8; display: flex; align-items: center; justify-content: space-between; }
        .badge { font-size: 11px; background: #0284c7; color: white; padding: 4px 8px; border-radius: 6px; font-weight: bold; }
        .status-box { padding: 14px 16px; border-radius: 8px; font-weight: bold; margin: 16px 0; display: flex; align-items: center; justify-content: space-between; background: #334155; }
        .status-left { display: flex; align-items: center; gap: 10px; }
        .dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
        .dot.green { background: #22c55e; box-shadow: 0 0 10px #22c55e; }
        .dot.yellow { background: #eab308; box-shadow: 0 0 10px #eab308; }
        .dot.red { background: #ef4444; }
        .stats-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin: 16px 0; }
        .stat-box { background: #0f172a; padding: 12px; border-radius: 8px; text-align: center; border: 1px solid #334155; }
        .stat-val { font-size: 18px; font-weight: bold; color: #38bdf8; }
        .stat-lbl { font-size: 11px; color: #94a3b8; margin-top: 4px; text-transform: uppercase; }
        label { display: block; font-size: 13px; color: #94a3b8; margin-top: 12px; margin-bottom: 4px; }
        input[type="text"] { width: 100%; box-sizing: border-box; padding: 10px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: white; font-size: 14px; }
        .checkbox-group { display: flex; gap: 20px; margin-top: 14px; margin-bottom: 6px; }
        .checkbox-group label { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #cbd5e1; cursor: pointer; margin: 0; }
        .checkbox-group input { width: 16px; height: 16px; accent-color: #0284c7; }
        .btn-group { display: flex; gap: 10px; margin-top: 16px; }
        button { flex: 1; padding: 12px; border-radius: 8px; border: none; font-weight: bold; font-size: 13px; cursor: pointer; transition: 0.2s; }
        .btn-start { background: #0284c7; color: white; }
        .btn-start:hover { background: #0369a1; }
        .btn-stop { background: #dc2626; color: white; }
        .btn-stop:hover { background: #b91c1c; }
        .btn-action { background: #475569; color: white; }
        .btn-action:hover { background: #64748b; }
        .logs-header { display: flex; justify-content: space-between; align-items: center; margin-top: 20px; }
        .logs-header label { margin: 0; }
        .btn-clear { background: transparent; border: 1px solid #475569; color: #94a3b8; padding: 4px 10px; border-radius: 6px; font-size: 11px; cursor: pointer; }
        .btn-clear:hover { background: #334155; color: white; }
        .logs { background: #090d16; border: 1px solid #334155; border-radius: 8px; padding: 12px; height: 180px; overflow-y: auto; font-family: monospace; font-size: 12px; margin-top: 8px; color: #cbd5e1; }
    </style>
</head>
<body>
    <div class="card">
        <h1>StationCast OME to NDI Bridge <span class="badge">Go Edition</span></h1>
        
        <div class="status-box">
            <div class="status-left">
                <span id="dot" class="dot red"></span>
                <span id="status">Disconnected</span>
            </div>
            <span id="mode" style="font-size: 12px; color: #cbd5e1;">Disconnected</span>
        </div>

        <div class="stats-grid">
            <div class="stat-box">
                <div id="stat-res" class="stat-val">1280x720</div>
                <div class="stat-lbl">Resolution</div>
            </div>
            <div class="stat-box">
                <div id="stat-fps" class="stat-val">0</div>
                <div class="stat-lbl">FPS</div>
            </div>
            <div class="stat-box">
                <div id="stat-frames" class="stat-val">0</div>
                <div class="stat-lbl">Total Frames</div>
            </div>
        </div>

        <form id="cfgForm">
            <label>OvenMediaEngine Host IP</label>
            <input type="text" id="host" value="75.119.149.43">
            <label>Stream Name</label>
            <input type="text" id="stream" value="field1">
            <label>NDI Output Source Name</label>
            <input type="text" id="ndi_name" value="Field1StationCast">
            <label>Standby Color Bars Image Path</label>
            <input type="text" id="standby_image" value="smpte_color_bars.webp">

            <div class="checkbox-group">
                <label><input type="checkbox" id="enable_logs" onchange="toggleLogs()"> Enable System Logging</label>
                <label><input type="checkbox" id="verbose_logs" onchange="toggleLogs()"> Verbose Frame Logging (Keyframes & FPS)</label>
            </div>

            <div class="btn-group">
                <button type="button" class="btn-start" onclick="startBridge()">Start NDI Bridge</button>
                <button type="button" class="btn-stop" onclick="stopBridge()">Stop Bridge</button>
            </div>
            <div class="btn-group">
                <button type="button" class="btn-action" onclick="requestPLI()">🚀 Force Keyframe (PLI)</button>
                <button type="button" class="btn-action" onclick="reloadStandby()">🎨 Reload Color Bars</button>
            </div>
        </form>

        <div class="logs-header">
            <label>System Logs</label>
            <button class="btn-clear" onclick="clearLogs()">Clear Console</button>
        </div>
        <div class="logs" id="logs"></div>
    </div>
    <script>
        async function fetchState() {
            try {
                const res = await fetch('/api/state');
                const data = await res.json();
                document.getElementById('status').innerText = data.status;
                document.getElementById('mode').innerText = data.mode || 'Disconnected';
                document.getElementById('dot').className = 'dot ' + (data.status_color || 'red');
                document.getElementById('stat-res').innerText = data.resolution || '1280x720';
                document.getElementById('stat-fps').innerText = data.fps || 0;
                document.getElementById('stat-frames').innerText = data.frame_count || 0;
                document.getElementById('enable_logs').checked = data.enable_logs;
                document.getElementById('verbose_logs').checked = data.verbose_logs;
                document.getElementById('logs').innerHTML = (data.logs || []).join('<br>');
                const logsDiv = document.getElementById('logs');
                logsDiv.scrollTop = logsDiv.scrollHeight;
            } catch(e) {}
        }
        async function startBridge() {
            const body = {
                host: document.getElementById('host').value,
                stream: document.getElementById('stream').value,
                ndi_name: document.getElementById('ndi_name').value,
                standby_image: document.getElementById('standby_image').value
            };
            await fetch('/api/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
        }
        async function stopBridge() {
            await fetch('/api/stop', { method: 'POST' });
        }
        async function requestPLI() {
            await fetch('/api/request_pli', { method: 'POST' });
        }
        async function reloadStandby() {
            const imgPath = document.getElementById('standby_image').value;
            await fetch('/api/reload_standby', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ standby_image: imgPath }) });
        }
        async function toggleLogs() {
            const body = {
                enable_logs: document.getElementById('enable_logs').checked,
                verbose_logs: document.getElementById('verbose_logs').checked
            };
            await fetch('/api/toggle_logs', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
        }
        async function clearLogs() {
            await fetch('/api/clear_logs', { method: 'POST' });
        }
        setInterval(fetchState, 1000);
        fetchState();
    </script>
</body>
</html>`

func main() {
	loadConfig()
	activeEngine = NewBridgeEngine()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(htmlPage))
	})

	http.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		state.Lock()
		data, _ := json.Marshal(state)
		state.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(data)
	})

	http.HandleFunc("/api/start", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)

		state.Lock()
		if h, ok := body["host"]; ok && h != "" {
			state.Host = h
		}
		if s, ok := body["stream"]; ok && s != "" {
			state.Stream = s
		}
		if n, ok := body["ndi_name"]; ok && n != "" {
			state.NDIName = n
		}
		if img, ok := body["standby_image"]; ok && img != "" {
			state.StandbyImage = img
		}
		h := state.Host
		s := state.Stream
		n := state.NDIName
		img := state.StandbyImage
		state.Unlock()

		saveConfig()
		activeEngine.Start(h, s, n, img)

		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/stop", func(w http.ResponseWriter, r *http.Request) {
		activeEngine.Stop()
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/request_pli", func(w http.ResponseWriter, r *http.Request) {
		activeEngine.RequestPLI()
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/reload_standby", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if img, ok := body["standby_image"]; ok && img != "" {
			state.Lock()
			state.StandbyImage = img
			state.Unlock()
			saveConfig()
			activeEngine.UpdateStandbyImage(img)
		}
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/toggle_logs", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]bool
		_ = json.NewDecoder(r.Body).Decode(&body)
		state.Lock()
		if e, ok := body["enable_logs"]; ok {
			state.EnableLogs = e
		}
		if v, ok := body["verbose_logs"]; ok {
			state.VerboseLogs = v
		}
		state.Unlock()
		saveConfig()
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/clear_logs", func(w http.ResponseWriter, r *http.Request) {
		state.Lock()
		state.Logs = make([]string, 0)
		state.Unlock()
		w.WriteHeader(http.StatusOK)
	})

	startPort := 7890
	var listener net.Listener
	actualPort := startPort

	for p := startPort; p < startPort+20; p++ {
		l, err := net.Listen("tcp", fmt.Sprintf(":%d", p))
		if err == nil {
			listener = l
			actualPort = p
			break
		}
	}

	if listener == nil {
		log.Fatalf("HTTP server error: Could not bind to any port in range %d-%d", startPort, startPort+20)
	}

	serverURL := fmt.Sprintf("http://localhost:%d", actualPort)
	addLog(fmt.Sprintf("Go StationCast NDI Bridge running at %s", serverURL))

	// Auto-start engine on launch
	activeEngine.Start(state.Host, state.Stream, state.NDIName, state.StandbyImage)

	// Auto-open browser
	go func() {
		time.Sleep(500 * time.Millisecond)
		openBrowser(serverURL)
	}()

	go func() {
		if err := http.Serve(listener, nil); err != nil {
			log.Fatalf("HTTP server error: %v", err)
		}
	}()

	setupSystray(activeEngine, actualPort)
}

func openBrowser(url string) {
	var err error
	switch runtime.GOOS {
	case "darwin":
		err = exec.Command("open", url).Start()
	case "windows":
		err = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "linux":
		err = exec.Command("xdg-open", url).Start()
	}
	if err != nil {
		log.Println("Could not open browser automatically:", err)
	}
}
