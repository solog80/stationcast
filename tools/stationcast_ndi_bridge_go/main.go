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

type StreamConfig struct {
	Stream       string `json:"stream"`
	NDIName      string `json:"ndi_name"`
	StandbyImage string `json:"standby_image"`
}

type Config struct {
	Host         string         `json:"host"`
	Stream       string         `json:"stream,omitempty"`
	NDIName      string         `json:"ndi_name,omitempty"`
	StandbyImage string         `json:"standby_image,omitempty"`
	Streams      []StreamConfig `json:"streams,omitempty"`
	EnableLogs   bool           `json:"enable_logs"`
	VerboseLogs  bool           `json:"verbose_logs"`
	// Transport forces the WebRTC media transport via OME's ?transport query param.
	// "" = OME default (UDP+Direct TCP), "tcp" = Direct TCP ICE only (RFC 6544),
	// "relay" = TURN relay, "all" = UDP+TCP+relay, "udp" = UDP only.
	Transport string `json:"transport,omitempty"`
	// PlayoutFrames is the NDI output jitter buffer depth in frames. Higher = smoother
	// on lossy/long links (absorbs stalls) at the cost of added latency. 0 = default (6).
	PlayoutFrames int `json:"playout_frames,omitempty"`
}

type StreamState struct {
	Stream       string `json:"stream"`
	NDIName      string `json:"ndi_name"`
	StandbyImage string `json:"standby_image"`
	Status       string `json:"status"`
	StatusColor  string `json:"status_color"`
	Mode         string `json:"mode"`
	Resolution   string `json:"resolution"`
	FPS          int    `json:"fps"`
	FrameCount   int64  `json:"frame_count"`
}

type AppState struct {
	sync.Mutex
	Host          string                  `json:"host"`
	Transport     string                  `json:"transport"`
	PlayoutFrames int                     `json:"playout_frames"`
	EnableLogs    bool                    `json:"enable_logs"`
	VerboseLogs   bool                    `json:"verbose_logs"`
	Streams       map[string]*StreamState `json:"streams"`
	Logs          []string                `json:"logs"`
}

var (
	appState = AppState{
		Host:          "158.220.126.145",
		PlayoutFrames: 6,
		EnableLogs:    true,
		VerboseLogs:   false,
		Streams:       make(map[string]*StreamState),
		Logs:          make([]string, 0),
	}
	engineManager = NewEngineManager()
	configFile    = "ndi_bridge_config.json"
)

// currentTransport returns the active WebRTC transport mode (guarded by appState).
func currentTransport() string {
	appState.Lock()
	defer appState.Unlock()
	return appState.Transport
}

// currentPlayoutFrames returns the configured NDI jitter buffer depth in frames.
func currentPlayoutFrames() int {
	appState.Lock()
	defer appState.Unlock()
	if appState.PlayoutFrames > 0 {
		return appState.PlayoutFrames
	}
	return 6
}

func addLog(msg string) {
	appState.Lock()
	defer appState.Unlock()
	if !appState.EnableLogs {
		return
	}
	log.Println(msg)
	appState.Logs = append(appState.Logs, fmt.Sprintf("[%s] %s", time.Now().Format("15:04:05"), msg))
	if len(appState.Logs) > 150 {
		appState.Logs = appState.Logs[1:]
	}
}

func addVerboseLog(msg string) {
	appState.Lock()
	enabled := appState.EnableLogs && appState.VerboseLogs
	appState.Unlock()
	if enabled {
		addLog(msg)
	}
}

func loadConfig() {
	appState.Lock()
	defer appState.Unlock()

	if data, err := os.ReadFile(configFile); err == nil {
		var cfg Config
		if err := json.Unmarshal(data, &cfg); err == nil {
			if cfg.Host != "" {
				appState.Host = cfg.Host
			}
			appState.EnableLogs = cfg.EnableLogs
			appState.VerboseLogs = cfg.VerboseLogs
			appState.Transport = cfg.Transport
			if cfg.PlayoutFrames > 0 {
				appState.PlayoutFrames = cfg.PlayoutFrames
			}

			if len(cfg.Streams) > 0 {
				for _, s := range cfg.Streams {
					if s.Stream != "" {
						ndi := s.NDIName
						if ndi == "" {
							ndi = fmt.Sprintf("%s_StationCast", strings.Title(s.Stream))
						}
						img := s.StandbyImage
						if img == "" {
							img = "smpte_color_bars.webp"
						}
						appState.Streams[s.Stream] = &StreamState{
							Stream:       s.Stream,
							NDIName:      ndi,
							StandbyImage: img,
							Status:       "Disconnected",
							StatusColor:  "red",
							Mode:         "Disconnected",
							Resolution:   "1280x720",
						}
					}
				}
			} else if cfg.Stream != "" {
				// Fallback for legacy single-stream configuration
				ndi := cfg.NDIName
				if ndi == "" {
					ndi = "Field1StationCast"
				}
				img := cfg.StandbyImage
				if img == "" {
					img = "smpte_color_bars.webp"
				}
				appState.Streams[cfg.Stream] = &StreamState{
					Stream:       cfg.Stream,
					NDIName:      ndi,
					StandbyImage: img,
					Status:       "Disconnected",
					StatusColor:  "red",
					Mode:         "Disconnected",
					Resolution:   "1280x720",
				}
			}
		}
	}

	// Default fallback streams if configuration file is missing or empty
	if len(appState.Streams) == 0 {
		appState.Streams["field1"] = &StreamState{
			Stream:       "field1",
			NDIName:      "Field_1_StationCast",
			StandbyImage: "smpte_color_bars.webp",
			Status:       "Disconnected",
			StatusColor:  "red",
			Mode:         "Disconnected",
			Resolution:   "1280x720",
		}
		appState.Streams["field2"] = &StreamState{
			Stream:       "field2",
			NDIName:      "Field_2_StationCast",
			StandbyImage: "smpte_color_bars.webp",
			Status:       "Disconnected",
			StatusColor:  "red",
			Mode:         "Disconnected",
			Resolution:   "1280x720",
		}
	}
}

func saveConfig() {
	appState.Lock()
	defer appState.Unlock()

	streams := make([]StreamConfig, 0, len(appState.Streams))
	for _, s := range appState.Streams {
		streams = append(streams, StreamConfig{
			Stream:       s.Stream,
			NDIName:      s.NDIName,
			StandbyImage: s.StandbyImage,
		})
	}

	cfg := Config{
		Host:          appState.Host,
		Transport:     appState.Transport,
		PlayoutFrames: appState.PlayoutFrames,
		Streams:       streams,
		EnableLogs:    appState.EnableLogs,
		VerboseLogs:   appState.VerboseLogs,
	}
	if data, err := json.MarshalIndent(cfg, "", "  "); err == nil {
		_ = os.WriteFile(configFile, data, 0644)
	}
}

type BridgeEngine struct {
	sync.Mutex
	streamName string
	ndiName    string
	standbyImg string
	running    bool
	ndi        *NDIBridge
	peerConn   *webrtc.PeerConnection
	activeSSRC uint32
	stopChan   chan struct{}
}

type EngineManager struct {
	sync.Mutex
	engines map[string]*BridgeEngine
}

func NewEngineManager() *EngineManager {
	return &EngineManager{
		engines: make(map[string]*BridgeEngine),
	}
}

func (m *EngineManager) StartStream(host, stream, ndiName, standbyImg string) {
	m.Lock()
	if eng, exists := m.engines[stream]; exists {
		eng.Stop()
	}
	eng := &BridgeEngine{
		streamName: stream,
		ndiName:    ndiName,
		standbyImg: standbyImg,
		stopChan:   make(chan struct{}),
	}
	m.engines[stream] = eng
	m.Unlock()

	appState.Lock()
	if appState.Streams == nil {
		appState.Streams = make(map[string]*StreamState)
	}
	appState.Streams[stream] = &StreamState{
		Stream:       stream,
		NDIName:      ndiName,
		StandbyImage: standbyImg,
		Status:       "Initializing NDI...",
		StatusColor:  "yellow",
		Mode:         "Standby (Color Bars)",
		Resolution:   "1280x720",
	}
	appState.Unlock()

	eng.Lock()
	eng.running = true
	eng.Unlock()

	go eng.runLoop(host, stream, ndiName, standbyImg)
}

func (m *EngineManager) StopStream(stream string) {
	m.Lock()
	eng, exists := m.engines[stream]
	if exists {
		delete(m.engines, stream)
	}
	m.Unlock()

	if exists && eng != nil {
		eng.Stop()
	}

	appState.Lock()
	if st, ok := appState.Streams[stream]; ok {
		st.Status = "Disconnected"
		st.StatusColor = "red"
		st.Mode = "Disconnected"
		st.FPS = 0
	}
	appState.Unlock()
}

func (m *EngineManager) StopAll() {
	m.Lock()
	engines := make([]*BridgeEngine, 0, len(m.engines))
	for _, e := range m.engines {
		engines = append(engines, e)
	}
	m.engines = make(map[string]*BridgeEngine)
	m.Unlock()

	for _, e := range engines {
		e.Stop()
	}

	appState.Lock()
	for _, st := range appState.Streams {
		st.Status = "Disconnected"
		st.StatusColor = "red"
		st.Mode = "Disconnected"
		st.FPS = 0
	}
	appState.Unlock()
}

func (m *EngineManager) StartAll() {
	appState.Lock()
	host := appState.Host
	streamList := make([]StreamConfig, 0, len(appState.Streams))
	for _, st := range appState.Streams {
		streamList = append(streamList, StreamConfig{
			Stream:       st.Stream,
			NDIName:      st.NDIName,
			StandbyImage: st.StandbyImage,
		})
	}
	appState.Unlock()

	for _, s := range streamList {
		m.StartStream(host, s.Stream, s.NDIName, s.StandbyImage)
	}
}

func (m *EngineManager) RequestPLI(targetStream string) {
	m.Lock()
	defer m.Unlock()

	if targetStream != "" {
		if eng, ok := m.engines[targetStream]; ok {
			eng.RequestPLI()
		}
		return
	}

	// Target all active engines
	for _, eng := range m.engines {
		eng.RequestPLI()
	}
}

func (m *EngineManager) UpdateStandbyImage(targetStream, imgPath string) {
	m.Lock()
	defer m.Unlock()

	if targetStream != "" {
		if eng, ok := m.engines[targetStream]; ok {
			eng.UpdateStandbyImage(imgPath)
		}
		return
	}

	for _, eng := range m.engines {
		eng.UpdateStandbyImage(imgPath)
	}
}

func (e *BridgeEngine) RequestPLI() {
	e.Lock()
	pc := e.peerConn
	ssrc := e.activeSSRC
	stream := e.streamName
	e.Unlock()

	if pc != nil && ssrc != 0 {
		addLog(fmt.Sprintf("🚀 Manual Keyframe Request (PLI) sent to stream '%s'", stream))
		_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
	} else {
		addLog(fmt.Sprintf("⚠️ Cannot send PLI to stream '%s': No active WebRTC connection", stream))
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
	if !e.running {
		e.Unlock()
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
	stream := e.streamName
	e.Unlock()

	appState.Lock()
	if st, ok := appState.Streams[stream]; ok {
		st.Status = "Disconnected"
		st.StatusColor = "red"
		st.Mode = "Disconnected"
		st.FPS = 0
	}
	appState.Unlock()
}

func (e *BridgeEngine) runLoop(host, stream, ndiName, standbyImg string) {
	cleanName := strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(ndiName, "(", ""), ")", ""), " ", ""), "_", "")
	if cleanName == "" {
		cleanName = fmt.Sprintf("%sStationCast", strings.Title(stream))
	}

	appState.Lock()
	if st, ok := appState.Streams[stream]; ok {
		st.Status = "Initializing NDI (Color Bars)..."
		st.StatusColor = "yellow"
		st.Mode = "Standby (Color Bars)"
	}
	appState.Unlock()

	ndiBridge, err := NewNDIBridge(cleanName, standbyImg)
	if err != nil {
		addLog(fmt.Sprintf("[%s] ERROR: %v", stream, err))
		appState.Lock()
		if st, ok := appState.Streams[stream]; ok {
			st.Status = "NDI Init Failed"
			st.StatusColor = "red"
			st.Mode = "Failed"
		}
		appState.Unlock()
		return
	}
	e.Lock()
	e.ndi = ndiBridge
	e.Unlock()
	addLog(fmt.Sprintf("NDI Stream published as '%s' for stream '%s' (Standby Color Bars Active)", cleanName, stream))

	for {
		e.Lock()
		running := e.running
		e.Unlock()
		if !running {
			break
		}

		connected := e.connectAndStream(host, stream)
		if connected {
			addLog(fmt.Sprintf("[%s] Live media stream finished.", stream))
		}

		e.Lock()
		running = e.running
		e.Unlock()
		if !running {
			break
		}

		e.Lock()
		if e.ndi != nil {
			e.ndi.SetLiveState(false)
		}
		e.Unlock()

		addLog(fmt.Sprintf("[%s] Waiting for stream publisher... Displaying SMPTE Color Bars (Retrying in 500ms)", stream))
		appState.Lock()
		if st, ok := appState.Streams[stream]; ok {
			st.Status = "Standby (SMPTE Color Bars)"
			st.StatusColor = "yellow"
			st.Mode = "Standby (Color Bars)"
			st.FPS = 30
		}
		appState.Unlock()

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
	if t := currentTransport(); t != "" {
		wsURL += "?transport=" + t
	}
	addLog(fmt.Sprintf("[%s] Connecting to OME WebSocket: %s", stream, wsURL))

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		addLog(fmt.Sprintf("[%s] WebSocket Dial Error: %v", stream, err))
		return false
	}
	defer conn.Close()

	var wsLock sync.Mutex

	addLog(fmt.Sprintf("[%s] Requesting offer from OME...", stream))
	wsLock.Lock()
	err = conn.WriteJSON(map[string]string{"command": "request_offer"})
	wsLock.Unlock()
	if err != nil {
		addLog(fmt.Sprintf("[%s] Request offer write error: %v", stream, err))
		return false
	}

	var offerMsg OMEMessage
	if err := conn.ReadJSON(&offerMsg); err != nil {
		addLog(fmt.Sprintf("[%s] Read offer error: %v", stream, err))
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
		addLog(fmt.Sprintf("[%s] ERROR: Invalid offer SDP received", stream))
		return false
	}

	offerSDPStr = preferH264InSDP(offerSDPStr, stream)

	offerMid := "0"
	for _, l := range strings.Split(offerSDPStr, "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "a=mid:") {
			offerMid = strings.TrimPrefix(l, "a=mid:")
			break
		}
	}

	m := &webrtc.MediaEngine{}
	rtcpFbVideo := []webrtc.RTCPFeedback{
		{Type: webrtc.TypeRTCPFBNACK},
		{Type: webrtc.TypeRTCPFBNACK, Parameter: "pli"},
		{Type: webrtc.TypeRTCPFBTransportCC},
		{Type: "goog-remb", Parameter: ""},
	}

	h264Fmtps := []string{
		"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
		"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f",
		"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f",
		"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f",
	}
	for idx, fmtp := range h264Fmtps {
		_ = m.RegisterCodec(webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				Channels:     0,
				SDPFmtpLine:  fmtp,
				RTCPFeedback: rtcpFbVideo,
			},
			PayloadType: webrtc.PayloadType(102 + idx),
		}, webrtc.RTPCodecTypeVideo)
	}

	_ = m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeVP8,
			ClockRate:    90000,
			Channels:     0,
			SDPFmtpLine:  "",
			RTCPFeedback: rtcpFbVideo,
		},
		PayloadType: 96,
	}, webrtc.RTPCodecTypeVideo)

	// RTX (retransmission) for H.264. Without this the answer never negotiates NACK/RTX,
	// so any packet lost on the (long) path to the server is gone for good — unlike a browser,
	// which recovers it via retransmission. apt must match the H.264 payload type OME offers.
	_ = m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    "video/rtx",
			ClockRate:   90000,
			SDPFmtpLine: "apt=98",
		},
		PayloadType: 99,
	}, webrtc.RTPCodecTypeVideo)
	addLog(fmt.Sprintf("[%s] Registered RTX for H.264 (apt=98, pt=99) — NACK retransmission enabled", stream))

	_ = m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeOpus,
			ClockRate:    48000,
			Channels:     2,
			SDPFmtpLine:  "minptime=10;useinbandfec=1",
			RTCPFeedback: nil,
		},
		PayloadType: 111,
	}, webrtc.RTPCodecTypeAudio)

	i := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(m, i); err != nil {
		addLog(fmt.Sprintf("[%s] Register default interceptors error: %v", stream, err))
		return false
	}

	se := webrtc.SettingEngine{}
	se.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
	se.SetICETimeouts(15*time.Second, 30*time.Second, 1*time.Second)
	// Enable ICE-TCP (RFC 6544) when a TCP-ish transport is requested, so Pion can dial
	// OME's Direct TCP ICE candidates on lossy/hostile networks.
	if t := currentTransport(); t == "tcp" || t == "relay" || t == "all" {
		se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeTCP4})
		se.DisableActiveTCP(false)
	}

	api := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(i), webrtc.WithSettingEngine(se))
	pc, err := api.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{
			{
				URLs: []string{"stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"},
			},
		},
	})
	if err != nil {
		addLog(fmt.Sprintf("[%s] Pion PeerConnection error: %v", stream, err))
		return false
	}
	e.Lock()
	e.peerConn = pc
	e.Unlock()

	pc.OnICEConnectionStateChange(func(connectionState webrtc.ICEConnectionState) {
		addLog(fmt.Sprintf("[%s] ICE Connection State: %s", stream, connectionState.String()))
		if connectionState == webrtc.ICEConnectionStateFailed ||
			connectionState == webrtc.ICEConnectionStateClosed {
			addLog(fmt.Sprintf("⚠️ Stream '%s' connection failed. Fast reconnecting...", stream))
			_ = pc.Close()
		} else if connectionState == webrtc.ICEConnectionStateDisconnected {
			addLog(fmt.Sprintf("⚠️ Stream '%s' transient ICE disconnect (re-evaluating candidates)...", stream))
		}
	})

	// Trickle local ICE candidates to OME over WebSocket
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
		addLog(fmt.Sprintf("[%s] AddTransceiver video error: %v", stream, err))
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		addLog(fmt.Sprintf("[%s] AddTransceiver audio error: %v", stream, err))
	}

	doneChan := make(chan struct{})

	pc.OnTrack(func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		addLog(fmt.Sprintf("🎥 [%s] TRACK ARRIVED: %s (Codec: %s, SSRC: %d)", stream, track.Kind().String(), track.Codec().MimeType, track.SSRC()))
		if track.Kind() == webrtc.RTPCodecTypeVideo {
			e.Lock()
			e.activeSSRC = uint32(track.SSRC())
			e.Unlock()
			go e.handleVideoTrack(track, pc, doneChan)
		} else if track.Kind() == webrtc.RTPCodecTypeAudio {
			go e.handleAudioTrack(track)
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  offerSDPStr,
	}); err != nil {
		addLog(fmt.Sprintf("[%s] SetRemoteDescription error: %v", stream, err))
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
		addLog(fmt.Sprintf("[%s] CreateAnswer error: %v", stream, err))
		return false
	}

	if err := pc.SetLocalDescription(answer); err != nil {
		addLog(fmt.Sprintf("[%s] SetLocalDescription error: %v", stream, err))
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
		addLog(fmt.Sprintf("[%s] Answer write error: %v", stream, err))
		return false
	}

	addLog(fmt.Sprintf("🟢 [%s] CONNECTED via WebRTC! Live media streaming -> NDI outputting.", stream))
	appState.Lock()
	if st, ok := appState.Streams[stream]; ok {
		st.Status = "Streaming Live NDI"
		st.StatusColor = "green"
		st.Mode = "Live Stream"
	}
	appState.Unlock()

	<-doneChan
	return true
}

// rtpHealth tracks RTP loss, jitter (RFC 3550) and throughput from the raw stream,
// since Pion v3 GetStats() exposes neither.
type rtpHealth struct {
	mu         sync.Mutex
	baseSeq    int64
	highestSeq int64
	received   int64
	bytes      int64
	haveBase   bool
	jitter     float64
	lastRTP    uint32
	lastArr    time.Time
	haveTiming bool
}

func (h *rtpHealth) observe(seq uint16, rtpTime uint32, size int, clockRate float64, arr time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()

	s := int64(seq)
	if !h.haveBase {
		h.baseSeq = s
		h.highestSeq = s
		h.haveBase = true
	} else {
		for s < h.highestSeq-32768 {
			s += 65536
		}
		for s > h.highestSeq+32768 {
			s -= 65536
		}
		if s > h.highestSeq {
			h.highestSeq = s
		}
	}
	h.received++
	h.bytes += int64(size)

	if clockRate > 0 {
		if h.haveTiming {
			arrivalDiff := arr.Sub(h.lastArr).Seconds() * clockRate
			rtpDiff := float64(int32(rtpTime - h.lastRTP))
			d := arrivalDiff - rtpDiff
			if d < 0 {
				d = -d
			}
			h.jitter += (d - h.jitter) / 16.0
		} else {
			h.haveTiming = true
		}
		h.lastRTP = rtpTime
		h.lastArr = arr
	}
}

// snapshot returns cumulative received, lost, loss %, jitter (ms) and bytes.
func (h *rtpHealth) snapshot(clockRate float64) (received, lost int64, lossPct, jitterMs float64, bytes int64) {
	h.mu.Lock()
	defer h.mu.Unlock()

	received = h.received
	bytes = h.bytes
	if h.haveBase {
		expected := h.highestSeq - h.baseSeq + 1
		lost = expected - h.received
		if lost < 0 {
			lost = 0
		}
		if expected > 0 {
			lossPct = float64(lost) / float64(expected) * 100
		}
	}
	if clockRate > 0 {
		jitterMs = h.jitter / clockRate * 1000.0
	}
	return
}

func (e *BridgeEngine) handleVideoTrack(track *webrtc.TrackRemote, pc *webrtc.PeerConnection, doneChan chan struct{}) {
	stream := e.streamName
	defer func() {
		if r := recover(); r != nil {
			addLog(fmt.Sprintf("⚠️ [%s] Recovered from video decoder pipeline panic: %v", stream, r))
		}
		close(doneChan)
	}()
	// Closed when this track ends, so the per-track helper goroutines stop on reconnect
	// instead of leaking (e.running stays true across reconnects).
	trackDone := make(chan struct{})
	defer close(trackDone)
	mime := track.Codec().MimeType
	isH264 := strings.EqualFold(mime, webrtc.MimeTypeH264)
	addLog(fmt.Sprintf("⚡ [%s] Starting %s Video Decoder & NDI Pipeline... (SSRC: %d)", stream, mime, track.SSRC()))

	decoder, err := NewVideoDecoder(mime)
	if err != nil {
		addLog(fmt.Sprintf("[%s] ERROR: Failed to create %s Video Decoder: %v", stream, mime, err))
		return
	}
	defer decoder.Close()
	addLog(fmt.Sprintf("⚙️ [%s] %s video decoder ready — acceleration: %s", stream, mime, decoder.HWDeviceName()))

	var builder *samplebuilder.SampleBuilder
	if isH264 {
		builder = samplebuilder.New(500, &codecs.H264Packet{}, track.Codec().ClockRate)
	} else {
		builder = samplebuilder.New(500, &codecs.VP8Packet{}, track.Codec().ClockRate)
	}

	var totalFrames int64
	var framesInSecond int64
	var droppedFrames int64
	var pipelineNanos int64
	health := &rtpHealth{}
	lastPLI := time.Time{}
	// Rate-limited keyframe request: a missing / undecodable I-Frame must not trigger a PLI storm.
	requestKeyframe := func() {
		if time.Since(lastPLI) < 250*time.Millisecond {
			return
		}
		lastPLI = time.Now()
		_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: uint32(track.SSRC())}})
	}
	// Ask for an initial keyframe before the decode worker starts (avoids a data race on lastPLI).
	requestKeyframe()

	// Decoding runs on its own goroutine so a slow decoder can never stall the RTP
	// read loop. Stalling that loop backs up the ICE/DTLS socket and drops the connection.
	frameChan := make(chan []byte, 64)
	var decodeWG sync.WaitGroup
	decodeWG.Add(1)
	go func() {
		defer decodeWG.Done()
		defer func() {
			if r := recover(); r != nil {
				addLog(fmt.Sprintf("⚠️ [%s] Recovered from video decoder pipeline panic: %v", stream, r))
			}
		}()

		gotKeyframe := false
		for frameData := range frameChan {
			if len(frameData) == 0 {
				continue
			}

			var isKeyframe bool
			if isH264 {
				isKeyframe = isH264Keyframe(frameData)
			} else {
				isKeyframe = (frameData[0] & 0x01) == 0
			}

			if !gotKeyframe {
				if !isKeyframe {
					requestKeyframe()
					continue
				}
				gotKeyframe = true
			}

			tFrame := time.Now()
			w, h, bgraSlice, stride, err := decoder.Decode(frameData)
			if err != nil || w <= 0 || h <= 0 || len(bgraSlice) == 0 {
				gotKeyframe = false
				requestKeyframe()
				continue
			}

			e.Lock()
			ndiBridge := e.ndi
			e.Unlock()

			if ndiBridge != nil {
				ndiBridge.SendVideo(w, h, bgraSlice, stride)
				atomic.AddInt64(&pipelineNanos, time.Since(tFrame).Nanoseconds())
				frameCount := atomic.AddInt64(&totalFrames, 1)
				atomic.AddInt64(&framesInSecond, 1)

				if isKeyframe {
					addVerboseLog(fmt.Sprintf("🔑 [%s] Synchronized %s Keyframe! Resolution: %dx%d", stream, mime, w, h))
					appState.Lock()
					if st, ok := appState.Streams[stream]; ok {
						st.Resolution = fmt.Sprintf("%dx%d", w, h)
					}
					appState.Unlock()
				}
				if frameCount%120 == 0 || frameCount == 1 {
					addVerboseLog(fmt.Sprintf("🎥 [%s] Rendered %d live video frames to NDI (%dx%d)", stream, frameCount, w, h))
				}
			}
		}
	}()

	// Stats reporting ticker per stream
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	go func() {
		var lastOut int64
		for {
			select {
			case <-trackDone:
				return
			case <-ticker.C:
				atomic.SwapInt64(&framesInSecond, 0) // keep decode counter drained
				e.Lock()
				ndi := e.ndi
				e.Unlock()
				outFPS := 0
				if ndi != nil {
					of := ndi.OutFrames()
					outFPS = int(of - lastOut)
					lastOut = of
				}
				appState.Lock()
				if st, ok := appState.Streams[stream]; ok {
					st.FPS = outFPS // real NDI output rate (steady), not decode throughput
					st.FrameCount = atomic.LoadInt64(&totalFrames)
				}
				appState.Unlock()
			}
		}
	}()

	// Periodic network-health stats (loss / jitter / RTT / bitrate) for chasing instability.
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		clockRate := float64(track.Codec().ClockRate)
		var lastBytes int64
		var lastTime time.Time
		var lastDecoded int64
		var lastPipeNanos int64
		for {
			select {
			case <-trackDone:
				return
			case <-ticker.C:
			}

			received, lost, lossPct, jitterMs, bytes := health.snapshot(clockRate)

			now := time.Now()
			kbps := 0.0
			if !lastTime.IsZero() {
				if dt := now.Sub(lastTime).Seconds(); dt > 0 {
					kbps = float64(bytes-lastBytes) * 8 / 1000.0 / dt
				}
			}
			lastBytes = bytes
			lastTime = now

			decoded := atomic.LoadInt64(&totalFrames)
			pipeNanos := atomic.LoadInt64(&pipelineNanos)
			avgPipeMs := 0.0
			if decoded > lastDecoded {
				avgPipeMs = float64(pipeNanos-lastPipeNanos) / float64(decoded-lastDecoded) / 1e6
			}
			lastDecoded = decoded
			lastPipeNanos = pipeNanos

			rttMs := -1.0
			for _, s := range pc.GetStats() {
				var cp *webrtc.ICECandidatePairStats
				switch v := s.(type) {
				case webrtc.ICECandidatePairStats:
					c := v
					cp = &c
				case *webrtc.ICECandidatePairStats:
					cp = v
				}
				if cp != nil && cp.Nominated && cp.State == webrtc.StatsICECandidatePairStateSucceeded {
					rttMs = cp.CurrentRoundTripTime * 1000
				}
			}

			addLog(fmt.Sprintf("📊 [%s] net %.0f kbps | loss %d/%d (%.2f%%) | jitter %.1f ms | RTT %.0f ms | decoded %d | drops %d | pipe %.1f ms",
				stream, kbps, lost, received+lost, lossPct, jitterMs, rttMs,
				decoded, atomic.LoadInt64(&droppedFrames), avgPipeMs))
		}
	}()

	// RTP read loop: stays lightweight and never blocks on decode/NDI.
	for {
		e.Lock()
		running := e.running
		e.Unlock()
		if !running {
			break
		}

		pkt, _, err := track.ReadRTP()
		if err != nil {
			addLog(fmt.Sprintf("[%s] ReadRTP error: %v", stream, err))
			break
		}

		health.observe(pkt.SequenceNumber, pkt.Timestamp, len(pkt.Payload), float64(track.Codec().ClockRate), time.Now())

		builder.Push(pkt)

		for {
			sample := builder.Pop()
			if sample == nil {
				break
			}
			if len(sample.Data) == 0 {
				continue
			}
			select {
			case frameChan <- sample.Data:
			default:
				// Decoder is behind: drop this frame instead of stalling RTP intake.
				atomic.AddInt64(&droppedFrames, 1)
			}
		}
	}

	close(frameChan)
	decodeWG.Wait()
}

func (e *BridgeEngine) handleAudioTrack(track *webrtc.TrackRemote) {
	stream := e.streamName
	defer func() {
		if r := recover(); r != nil {
			addLog(fmt.Sprintf("⚠️ [%s] Recovered from audio decoder pipeline panic: %v", stream, r))
		}
	}()
	mime := track.Codec().MimeType
	addLog(fmt.Sprintf("🔊 [%s] Starting %s Opus Audio Receiver & NDI Audio Pipeline... (SSRC: %d)", stream, mime, track.SSRC()))

	audioDec, err := NewAudioDecoder()
	if err != nil {
		addLog(fmt.Sprintf("[%s] WARNING: Opus Audio Decoder init failed: %v", stream, err))
		return
	}
	defer audioDec.Close()

	builder := samplebuilder.New(200, &codecs.OpusPacket{}, track.Codec().ClockRate)

	for {
		e.Lock()
		running := e.running
		e.Unlock()
		if !running {
			break
		}

		pkt, _, err := track.ReadRTP()
		if err != nil {
			break
		}

		builder.Push(pkt)

		for {
			sample := builder.Pop()
			if sample == nil {
				break
			}
			if len(sample.Data) == 0 {
				continue
			}

			sampleRate, channels, numSamples, floatBuf, err := audioDec.Decode(sample.Data)
			if err != nil || numSamples <= 0 || len(floatBuf) == 0 {
				continue
			}

			e.Lock()
			ndiBridge := e.ndi
			e.Unlock()

			if ndiBridge != nil {
				ndiBridge.SendAudio(sampleRate, channels, numSamples, floatBuf)
			}
		}
	}
}

func isH264Keyframe(data []byte) bool {
	if len(data) < 5 {
		return false
	}
	for i := 0; i < len(data)-4; i++ {
		if data[i] == 0 && data[i+1] == 0 {
			offset := 0
			if data[i+2] == 1 {
				offset = i + 3
			} else if data[i+2] == 0 && data[i+3] == 1 {
				offset = i + 4
			}
			if offset > 0 && offset < len(data) {
				nalType := data[offset] & 0x1F
				if nalType == 5 || nalType == 7 || nalType == 8 {
					return true
				}
			}
		}
	}
	return false
}

func preferH264InSDP(sdp string, stream string) string {
	lines := strings.Split(sdp, "\n")
	h264Pts := []string{}

	for _, l := range lines {
		lTrim := strings.TrimSpace(l)
		if strings.HasPrefix(lTrim, "a=rtpmap:") && strings.Contains(strings.ToUpper(lTrim), "H264/") {
			parts := strings.Split(strings.TrimPrefix(lTrim, "a=rtpmap:"), " ")
			if len(parts) > 0 {
				h264Pts = append(h264Pts, parts[0])
			}
		}
	}

	if len(h264Pts) == 0 {
		addLog(fmt.Sprintf("[%s] SDP Offer contains no H.264 payload types. Fallback to default codecs.", stream))
		return sdp
	}

	addLog(fmt.Sprintf("[%s] Preferring H.264 payload types in SDP Offer: %v", stream, h264Pts))

	for i, l := range lines {
		lTrim := strings.TrimSpace(l)
		if strings.HasPrefix(lTrim, "m=video ") {
			fields := strings.Fields(lTrim)
			if len(fields) >= 4 {
				header := fields[:3]
				pts := fields[3:]

				newPts := append([]string{}, h264Pts...)
				for _, pt := range pts {
					alreadyAdded := false
					for _, hPT := range h264Pts {
						if pt == hPT {
							alreadyAdded = true
							break
						}
					}
					if !alreadyAdded {
						newPts = append(newPts, pt)
					}
				}
				lines[i] = strings.Join(append(header, newPts...), " ")
			}
		}
	}

	return strings.Join(lines, "\n")
}

// Multi-Channel HTTP Web Dashboard
const htmlPage = `<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>StationCast Multi-Stream NDI Bridge (Go Edition)</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 20px; }
        .container { max-width: 900px; margin: 0 auto; }
        .card { background: #1e293b; border-radius: 12px; padding: 24px; margin-bottom: 20px; box-shadow: 0 10px 25px rgba(0,0,0,0.5); }
        h1 { margin-top: 0; font-size: 22px; color: #38bdf8; display: flex; align-items: center; justify-content: space-between; }
        .badge { font-size: 11px; background: #0284c7; color: white; padding: 4px 8px; border-radius: 6px; font-weight: bold; }
        .streams-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(400px, 1fr)); gap: 16px; margin-top: 16px; }
        .stream-card { background: #0f172a; border: 1px solid #334155; border-radius: 10px; padding: 16px; }
        .stream-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
        .stream-title { font-size: 16px; font-weight: bold; color: #f8fafc; }
        .ndi-badge { font-size: 11px; background: #334155; color: #38bdf8; padding: 3px 6px; border-radius: 4px; font-family: monospace; }
        .status-box { padding: 10px 12px; border-radius: 8px; font-weight: bold; margin-bottom: 12px; display: flex; align-items: center; justify-content: space-between; background: #1e293b; font-size: 13px; }
        .status-left { display: flex; align-items: center; gap: 8px; }
        .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
        .dot.green { background: #22c55e; box-shadow: 0 0 8px #22c55e; }
        .dot.yellow { background: #eab308; box-shadow: 0 0 8px #eab308; }
        .dot.red { background: #ef4444; }
        .stats-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-bottom: 12px; }
        .stat-box { background: #1e293b; padding: 8px; border-radius: 6px; text-align: center; border: 1px solid #334155; }
        .stat-val { font-size: 15px; font-weight: bold; color: #38bdf8; }
        .stat-lbl { font-size: 10px; color: #94a3b8; margin-top: 2px; text-transform: uppercase; }
        label { display: block; font-size: 12px; color: #94a3b8; margin-top: 10px; margin-bottom: 4px; }
        input[type="text"] { width: 100%; box-sizing: border-box; padding: 8px 10px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: white; font-size: 13px; }
        .checkbox-group { display: flex; gap: 20px; margin-top: 14px; margin-bottom: 6px; }
        .checkbox-group label { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #cbd5e1; cursor: pointer; margin: 0; }
        .checkbox-group input { width: 16px; height: 16px; accent-color: #0284c7; }
        .btn-group { display: flex; gap: 8px; margin-top: 12px; }
        button { flex: 1; padding: 10px; border-radius: 6px; border: none; font-weight: bold; font-size: 12px; cursor: pointer; transition: 0.2s; }
        .btn-start { background: #0284c7; color: white; }
        .btn-start:hover { background: #0369a1; }
        .btn-stop { background: #dc2626; color: white; }
        .btn-stop:hover { background: #b91c1c; }
        .btn-action { background: #475569; color: white; }
        .btn-action:hover { background: #64748b; }
        .btn-delete { background: #991b1b; color: white; flex: 0.5; }
        .btn-delete:hover { background: #7f1d1d; }
        .logs-header { display: flex; justify-content: space-between; align-items: center; margin-top: 20px; }
        .logs-header label { margin: 0; }
        .btn-clear { background: transparent; border: 1px solid #475569; color: #94a3b8; padding: 4px 10px; border-radius: 6px; font-size: 11px; cursor: pointer; }
        .btn-clear:hover { background: #334155; color: white; }
        .logs { background: #090d16; border: 1px solid #334155; border-radius: 8px; padding: 12px; height: 180px; overflow-y: auto; font-family: monospace; font-size: 12px; margin-top: 8px; color: #cbd5e1; }
        .add-card { border: 2px dashed #334155; background: #0f172a; padding: 16px; border-radius: 10px; margin-top: 16px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <h1>StationCast Multi-Stream NDI Bridge <span class="badge">Go Edition</span></h1>
            
            <div style="display: flex; gap: 12px; align-items: flex-end; margin-bottom: 16px; flex-wrap: wrap;">
                <div style="flex: 1 1 200px; min-width: 180px;">
                    <label>OvenMediaEngine Host IP</label>
                    <input type="text" id="host" value="158.220.126.145">
                </div>
                <div style="flex: 0 1 210px; min-width: 180px;">
                    <label>WebRTC Media Transport</label>
                    <select id="transport" style="width:100%; box-sizing:border-box; padding:8px 10px; border-radius:6px; border:1px solid #475569; background:#0f172a; color:white; font-size:13px;">
                        <option value="">UDP + TCP (default)</option>
                        <option value="tcp">TCP only (Direct ICE, RFC 6544)</option>
                        <option value="udp">UDP only</option>
                        <option value="relay">TURN relay (TCP)</option>
                        <option value="all">UDP → TCP → Relay (fallback)</option>
                    </select>
                </div>
                <div style="flex: 0 1 180px; min-width: 150px;">
                    <label>NDI Playout Buffer (frames)</label>
                    <input type="number" id="playout_frames" min="1" max="24" step="1" value="6">
                </div>
                <button class="btn-start" style="flex: 0 0 150px; height: 36px;" onclick="updateHost()">Update Host IP</button>
                <button class="btn-start" style="flex: 0 0 150px; height: 36px; background:#0d9488;" onclick="updateTransport()">Apply Transport</button>
                <button class="btn-start" style="flex: 0 0 150px; height: 36px; background:#0d9488;" onclick="updatePlayout()">Apply Buffer</button>
            </div>

            <div class="checkbox-group">
                <label><input type="checkbox" id="enable_logs" onchange="toggleLogs()"> Enable System Logging</label>
                <label><input type="checkbox" id="verbose_logs" onchange="toggleLogs()"> Verbose Frame Logging (Keyframes & FPS)</label>
            </div>

            <div class="btn-group">
                <button type="button" class="btn-start" onclick="startAllStreams()">▶️ Start All Streams</button>
                <button type="button" class="btn-stop" onclick="stopAllStreams()">⏹️ Stop All Streams</button>
                <button type="button" class="btn-action" onclick="requestAllPLI()">🚀 Force Keyframe All (PLI)</button>
            </div>
        </div>

        <div class="card">
            <h2 style="margin-top: 0; font-size: 18px; color: #38bdf8;">🎥 Contributor Channels</h2>
            <div class="streams-grid" id="streamsGrid"></div>

            <div class="add-card">
                <h3 style="margin-top: 0; font-size: 15px; color: #cbd5e1;">➕ Add Contributor Stream Channel</h3>
                <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px;">
                    <div>
                        <label>Stream Name</label>
                        <input type="text" id="new_stream" placeholder="e.g. field3">
                    </div>
                    <div>
                        <label>NDI Output Name</label>
                        <input type="text" id="new_ndi" placeholder="e.g. Field_3_StationCast">
                    </div>
                    <div>
                        <label>Standby Image</label>
                        <input type="text" id="new_standby" value="smpte_color_bars.webp">
                    </div>
                </div>
                <button class="btn-start" style="margin-top: 12px; width: 100%;" onclick="addStreamChannel()">Add & Start Contributor Stream</button>
            </div>
        </div>

        <div class="card">
            <div class="logs-header">
                <label>System Logs</label>
                <button class="btn-clear" onclick="clearLogs()">Clear Console</button>
            </div>
            <div class="logs" id="logs"></div>
        </div>
    </div>

    <script>
        async function fetchState() {
            try {
                const res = await fetch('/api/state');
                const data = await res.json();
                document.getElementById('host').value = data.host || '158.220.126.145';
                document.getElementById('transport').value = data.transport || '';
                document.getElementById('playout_frames').value = data.playout_frames || 6;
                document.getElementById('enable_logs').checked = data.enable_logs;
                document.getElementById('verbose_logs').checked = data.verbose_logs;
                
                const grid = document.getElementById('streamsGrid');
                const streams = data.streams || {};
                
                let html = '';
                for (const key in streams) {
                    const s = streams[key];
                    html += '<div class="stream-card">' +
                        '<div class="stream-header">' +
                            '<div class="stream-title">📡 ' + s.stream + '</div>' +
                            '<div class="ndi-badge">NDI: ' + s.ndi_name + '</div>' +
                        '</div>' +
                        '<div class="status-box">' +
                            '<div class="status-left">' +
                                '<span class="dot ' + (s.status_color || 'red') + '"></span>' +
                                '<span>' + s.status + '</span>' +
                            '</div>' +
                            '<span style="font-size: 11px; color: #94a3b8;">' + (s.mode || 'Disconnected') + '</span>' +
                        '</div>' +
                        '<div class="stats-grid">' +
                            '<div class="stat-box"><div class="stat-val">' + (s.resolution || '1280x720') + '</div><div class="stat-lbl">Resolution</div></div>' +
                            '<div class="stat-box"><div class="stat-val">' + (s.fps || 0) + '</div><div class="stat-lbl">FPS</div></div>' +
                            '<div class="stat-box"><div class="stat-val">' + (s.frame_count || 0) + '</div><div class="stat-lbl">Frames</div></div>' +
                        '</div>' +
                        '<div class="btn-group">' +
                            '<button class="btn-start" onclick="startSingleStream(\'' + s.stream + '\')">▶️ Start</button>' +
                            '<button class="btn-stop" onclick="stopSingleStream(\'' + s.stream + '\')">⏹️ Stop</button>' +
                            '<button class="btn-action" onclick="requestPLI(\'' + s.stream + '\')">🚀 PLI</button>' +
                            '<button class="btn-delete" onclick="deleteSingleStream(\'' + s.stream + '\')">🗑️</button>' +
                        '</div>' +
                    '</div>';
                }
                grid.innerHTML = html || '<div style="color: #94a3b8; font-size: 13px;">No active stream channels configured.</div>';

                document.getElementById('logs').innerHTML = (data.logs || []).join('<br>');
                const logsDiv = document.getElementById('logs');
                logsDiv.scrollTop = logsDiv.scrollHeight;
            } catch(e) {}
        }

        async function updateHost() {
            const host = document.getElementById('host').value;
            await fetch('/api/update_host', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ host }) });
        }
        async function updateTransport() {
            const transport = document.getElementById('transport').value;
            await fetch('/api/update_transport', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ transport }) });
        }
        async function updatePlayout() {
            const playout_frames = parseInt(document.getElementById('playout_frames').value, 10) || 6;
            await fetch('/api/update_playout', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ playout_frames }) });
        }
        async function startAllStreams() {
            await fetch('/api/start_all', { method: 'POST' });
        }
        async function stopAllStreams() {
            await fetch('/api/stop_all', { method: 'POST' });
        }
        async function startSingleStream(stream) {
            await fetch('/api/start_stream', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ stream }) });
        }
        async function stopSingleStream(stream) {
            await fetch('/api/stop_stream', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ stream }) });
        }
        async function requestPLI(stream) {
            await fetch('/api/request_pli', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ stream }) });
        }
        async function requestAllPLI() {
            await fetch('/api/request_pli', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ stream: '' }) });
        }
        async function deleteSingleStream(stream) {
            if (confirm('Remove channel ' + stream + '?')) {
                await fetch('/api/delete_stream', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ stream }) });
            }
        }
        async function addStreamChannel() {
            const stream = document.getElementById('new_stream').value;
            const ndi = document.getElementById('new_ndi').value || (stream + '_StationCast');
            const standby = document.getElementById('new_standby').value || 'smpte_color_bars.webp';
            if (!stream) return alert('Enter stream name');
            await fetch('/api/add_stream', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ stream, ndi_name: ndi, standby_image: standby })
            });
            document.getElementById('new_stream').value = '';
            document.getElementById('new_ndi').value = '';
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

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(htmlPage))
	})

	http.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		appState.Lock()
		data, _ := json.Marshal(appState)
		appState.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(data)
	})

	http.HandleFunc("/api/update_host", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if h, ok := body["host"]; ok && h != "" {
			appState.Lock()
			appState.Host = h
			appState.Unlock()
			saveConfig()
		}
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/update_transport", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		t := strings.ToLower(strings.TrimSpace(body["transport"]))
		if t == "udptcp" || t == "default" {
			t = ""
		}
		switch t {
		case "", "udp", "tcp", "relay", "all":
			appState.Lock()
			appState.Transport = t
			appState.Unlock()
			saveConfig()
			// Transport is baked into the ICE setup at connect time, so restart streams to apply it.
			engineManager.StopAll()
			engineManager.StartAll()
			label := t
			if label == "" {
				label = "default (UDP+TCP)"
			}
			addLog(fmt.Sprintf("🔀 WebRTC media transport set to '%s' — restarting streams", label))
			w.WriteHeader(http.StatusOK)
		default:
			http.Error(w, "invalid transport (use '', udp, tcp, relay, all)", http.StatusBadRequest)
		}
	})

	http.HandleFunc("/api/update_playout", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		v, ok := body["playout_frames"].(float64)
		if !ok {
			http.Error(w, "missing playout_frames", http.StatusBadRequest)
			return
		}
		n := int(v)
		if n < 1 {
			n = 1
		}
		if n > 24 {
			n = 24
		}
		appState.Lock()
		appState.PlayoutFrames = n
		appState.Unlock()
		saveConfig()
		addLog(fmt.Sprintf("🎛️ NDI playout buffer set to %d frames (~%d ms latency) — applies live", n, n*33))
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/start_all", func(w http.ResponseWriter, r *http.Request) {
		engineManager.StartAll()
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/stop_all", func(w http.ResponseWriter, r *http.Request) {
		engineManager.StopAll()
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/start_stream", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if s, ok := body["stream"]; ok && s != "" {
			appState.Lock()
			st, exists := appState.Streams[s]
			host := appState.Host
			appState.Unlock()

			if exists {
				engineManager.StartStream(host, st.Stream, st.NDIName, st.StandbyImage)
			}
		}
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/stop_stream", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if s, ok := body["stream"]; ok && s != "" {
			engineManager.StopStream(s)
		}
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/add_stream", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		s := body["stream"]
		if s != "" {
			ndi := body["ndi_name"]
			if ndi == "" {
				ndi = fmt.Sprintf("%s_StationCast", strings.Title(s))
			}
			img := body["standby_image"]
			if img == "" {
				img = "smpte_color_bars.webp"
			}
			appState.Lock()
			host := appState.Host
			appState.Streams[s] = &StreamState{
				Stream:       s,
				NDIName:      ndi,
				StandbyImage: img,
				Status:       "Initializing...",
				StatusColor:  "yellow",
				Mode:         "Standby",
				Resolution:   "1280x720",
			}
			appState.Unlock()
			saveConfig()
			engineManager.StartStream(host, s, ndi, img)
		}
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/delete_stream", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if s, ok := body["stream"]; ok && s != "" {
			engineManager.StopStream(s)
			appState.Lock()
			delete(appState.Streams, s)
			appState.Unlock()
			saveConfig()
		}
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/request_pli", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		targetStream := body["stream"]
		engineManager.RequestPLI(targetStream)
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/toggle_logs", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]bool
		_ = json.NewDecoder(r.Body).Decode(&body)
		appState.Lock()
		if e, ok := body["enable_logs"]; ok {
			appState.EnableLogs = e
		}
		if v, ok := body["verbose_logs"]; ok {
			appState.VerboseLogs = v
		}
		appState.Unlock()
		saveConfig()
		w.WriteHeader(http.StatusOK)
	})

	http.HandleFunc("/api/clear_logs", func(w http.ResponseWriter, r *http.Request) {
		appState.Lock()
		appState.Logs = make([]string, 0)
		appState.Unlock()
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
	addLog(fmt.Sprintf("Go StationCast Multi-Stream NDI Bridge running at %s", serverURL))

	// Auto-start all configured streams on startup
	engineManager.StartAll()

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

	setupSystray(engineManager, actualPort)
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
