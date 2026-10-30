package main

import (
	"encoding/json"
	"fmt"
	"strings"

	adaptix "github.com/Adaptix-Framework/axc2/v2"
)

type Teamserver interface {
	TsPluginServiceSendDataAll(service string, data string)
	TsPluginServiceSendDataClient(operator string, service string, data string)

	TsExtenderDataSave(extenderName string, key string, value []byte) error
	TsExtenderDataLoad(extenderName string, key string) ([]byte, error)
	TsExtenderDataDelete(extenderName string, key string) error
	TsExtenderDataKeys(extenderName string) ([]string, error)
}

type PluginService struct{}

var (
	Ts        Teamserver
	ModuleDir string
	SSLCert   string
	SSLKey    string
	SiteMgr   *SiteManager
)

func InitPlugin(ts any, moduleDir string, serviceConfig string) adaptix.PluginService {
	Ts = ts.(Teamserver)
	ModuleDir = moduleDir

	for _, line := range strings.Split(serviceConfig, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "ssl_cert:") {
			val := strings.TrimSpace(strings.TrimPrefix(line, "ssl_cert:"))
			SSLCert = strings.Trim(val, `"'`)
		}
		if strings.HasPrefix(line, "ssl_key:") {
			val := strings.TrimSpace(strings.TrimPrefix(line, "ssl_key:"))
			SSLKey = strings.Trim(val, `"'`)
		}
	}

	SiteMgr = NewSiteManager()
	if err := SiteMgr.RestoreAll(); err != nil {
		fmt.Printf("[FileHost] WARNING: failed to restore sites: %v\n", err)
	}

	fmt.Printf("[FileHost] Initialized - %d site(s) restored, ssl_cert=%s\n", SiteMgr.Count(), SSLCert)
	return &PluginService{}
}

func (p *PluginService) CallRPC(operator string, function string, args string) (string, error) {
	p.Call(operator, function, args)
	return "", nil
}

func (p *PluginService) Call(operator string, function string, args string) {
	switch function {
	case "host_file":
		go handleHostFile(operator, args)
	case "remove_site":
		go handleRemoveSite(operator, args)
	case "list_sites":
		go handleListSites(operator)
	case "generate_attack":
		go handleGenerateAttack(operator, args)
	default:
		sendError(operator, "Unknown function: "+function)
	}
}

func send(operator string, payload any) {
	j, _ := json.Marshal(payload)
	Ts.TsPluginServiceSendDataClient(operator, "FileHost", string(j))
}

func broadcast(payload any) {
	j, _ := json.Marshal(payload)
	Ts.TsPluginServiceSendDataAll("FileHost", string(j))
}

func sendError(operator string, msg string) {
	send(operator, map[string]string{"action": "error", "message": msg})
}
