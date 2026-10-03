package api

import (
	"context"
	"net/http"

	"github.com/danielgtaylor/huma/v2"

	"prototip/internal/panel/mtproto"
)

type mtprotoOutput struct {
	Body mtproto.View
}

type patchMTProtoInput struct {
	Body struct {
		Enabled *bool   `json:"enabled,omitempty"`
		Port    *int    `json:"port,omitempty" minimum:"1024" maximum:"65535"`
		Domain  *string `json:"domain,omitempty" maxLength:"253"`
	}
}

func (h *handlers) registerMTProto() {
	huma.Register(h.api, huma.Operation{OperationID: "get-mtproto", Metadata: sessionOnly, Extensions: sessionOnlyExt, Method: http.MethodGet, Path: "/api/v1/mtproto", Summary: "MTProto для Telegram", Tags: []string{"inbounds"}}, h.getMTProto)
	huma.Register(h.api, huma.Operation{OperationID: "update-mtproto", Metadata: sessionOnly, Extensions: sessionOnlyExt, Method: http.MethodPatch, Path: "/api/v1/mtproto", Summary: "Настроить MTProto", Tags: []string{"inbounds"}}, h.updateMTProto)
	huma.Register(h.api, huma.Operation{OperationID: "regenerate-mtproto", Metadata: sessionOnly, Extensions: sessionOnlyExt, Method: http.MethodPost, Path: "/api/v1/mtproto/regenerate", Summary: "Пересоздать секрет MTProto", Tags: []string{"inbounds"}}, h.regenerateMTProto)
}

func (h *handlers) getMTProto(ctx context.Context, _ *struct{}) (*mtprotoOutput, error) {
	v, err := h.d.MTProto.View(ctx)
	if err != nil {
		return nil, err
	}
	return &mtprotoOutput{Body: v}, nil
}

func (h *handlers) updateMTProto(ctx context.Context, in *patchMTProtoInput) (*mtprotoOutput, error) {
	v, err := h.d.MTProto.Update(ctx, mtproto.Update{Enabled: in.Body.Enabled, Port: in.Body.Port, Domain: in.Body.Domain}, false)
	if err != nil {
		switch err.Error() {
		case "mtproto_port_invalid", "mtproto_domain_invalid":
			return nil, huma.Error422UnprocessableEntity(err.Error())
		default:
			return nil, err
		}
	}
	h.audit(ctx, sessionOf(ctx).AdminID, "mtproto.update", "", "", map[string]any{"enabled": v.Enabled, "port": v.Port})
	return &mtprotoOutput{Body: v}, nil
}

func (h *handlers) regenerateMTProto(ctx context.Context, _ *struct{}) (*mtprotoOutput, error) {
	v, err := h.d.MTProto.Update(ctx, mtproto.Update{}, true)
	if err != nil {
		return nil, err
	}
	h.audit(ctx, sessionOf(ctx).AdminID, "mtproto.regenerate", "", "", nil)
	return &mtprotoOutput{Body: v}, nil
}
