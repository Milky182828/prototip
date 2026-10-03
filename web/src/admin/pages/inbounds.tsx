import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Copy, Pencil, Plus, RefreshCw, Send, Trash2, TriangleAlert } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { api, errorText, rawApi, unwrap, type Inbound, type MTProtoView, type Schemas } from "../../api/client";
import { qk, useInbounds, useMTProto, useNodes } from "../../api/hooks";
import { Confirm } from "../../components/overlay";
import { QueryBoundary } from "../../components/query";
import { useToast } from "../../components/toast";
import { Button, EmptyState, Field, PageHeader, Pill, Segmented, Skeleton } from "../../components/ui";
import { Switch } from "../../components/switch";
import { t, tMaybe } from "../../i18n";
import { ago, maskedAs } from "../../lib/format";
import { useCopy } from "../../lib/copy";
import { nodeLabel } from "./nodes";
import { hostPort, listenerError } from "./inbound/shared";
import { AddDrawer } from "./inbound/add";
import { EditDrawer } from "./inbound/edit";

export function InboundsPage() {
  const all = useInbounds();
  const nodes = useNodes();
  const qc = useQueryClient();
  const toast = useToast();
  const [picked, setNodeId] = useState<number | null>(null);
  // The panel's own node until the admin picks another one (its id is not a constant).
  const nodeId = picked ?? nodes.data?.find((n) => n.local)?.id ?? nodes.data?.[0]?.id ?? 1;
  const multi = (nodes.data?.length ?? 0) > 1;
  const node = nodes.data?.find((n) => n.id === nodeId);
  // One node: its inbounds are all there is; several: the chosen node's.
  const inbounds = useMemo(() => (all.data ?? []).filter((i) => !multi || i.node_id === nodeId), [all.data, multi, nodeId]);
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<Inbound | null>(null);
  const [removing, setRemoving] = useState<Inbound | null>(null);
  const patch = useMutation({
    mutationFn: ({ id, body }: { id: number; body: Schemas["PatchInboundInputBody"] }) => unwrap(api.PATCH("/api/v1/inbounds/{id}", { params: { path: { id } }, body })),
    onSettled: () => void qc.invalidateQueries({ queryKey: qk.inbounds }),
    onError: (e) => toast.error(errorText(e)),
  });
  const remove = useMutation({
    mutationFn: (id: number) => unwrap(api.DELETE("/api/v1/inbounds/{id}", { params: { path: { id } } })),
    onSuccess: () => {
      toast.ok(t("inbounds.deleted"));
      setRemoving(null);
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: qk.inbounds }),
    onError: (e) => toast.error(errorText(e)),
  });

  return (
    <>
      <PageHeader
        title={t("nav.inbounds")}
        sub={t("inbounds.subtitle")}
        actions={
          <Button variant="primary" onClick={() => setAdding(true)}>
            <Plus size={18} aria-hidden />
            <span className="max-[760px]:hidden">{t("common.add")}</span>
          </Button>
        }
      />
      <div className="banner warn">
        <TriangleAlert size={18} className="shrink-0" aria-hidden />
        <span>{t("inbounds.reconnectWarning")}</span>
      </div>
      <MTProtoCard />
      {multi && nodes.data ? (
        <div className="mb-4">
          <Segmented
            value={String(nodeId)}
            label={t("inbounds.node")}
            options={nodes.data.map((n) => ({ value: String(n.id), label: nodeLabel(n) }))}
            onChange={(v) => setNodeId(Number(v))}
          />
        </div>
      ) : null}
      <QueryBoundary
        query={all}
        pending={
          <div className="grid gap-4 lg:grid-cols-2">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} style={{ height: 150, borderRadius: 20 }} />
            ))}
          </div>
        }
        wrap={(state) => <section className="card glass">{state}</section>}
      >
        {() =>
          inbounds.length === 0 ? (
            <section className="card glass">
              <EmptyState title={multi ? t("inbounds.nodeEmptyTitle") : t("inbounds.emptyTitle")} text={multi ? t("inbounds.nodeEmptyText") : t("inbounds.emptyText")}>
                <Button variant="primary" onClick={() => setAdding(true)}>
                  <Plus size={18} aria-hidden /> {t("inbounds.add")}
                </Button>
              </EmptyState>
            </section>
          ) : (
            <div className="grid gap-4 lg:grid-cols-2">
              {inbounds.map((i, idx) => (
                <section key={i.id} className="card glass reveal" style={{ "--i": idx } as React.CSSProperties}>
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <h2 className="font-display truncate text-lg font-medium tracking-tight">{i.sub_name}</h2>
                      <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-[var(--ink-500)]">
                        <span>{i.preset === "custom" ? t("inbounds.customOf", { type: i.type }) : i.title}</span>
                        <span>·</span>
                        <span>{t("inbounds.port", { port: i.listen ? hostPort(i.listen, i.port) : i.port, network: i.network })}</span>
                        <span>·</span>
                        <span className="mono">{i.name}</span>
                      </div>
                    </div>
                    <Switch
                      checked={i.enabled}
                      label={t("inbounds.toggle", { name: i.sub_name })}
                      disabled={patch.isPending}
                      onChange={(v) => patch.mutate({ id: i.id, body: { enabled: v } }, { onSuccess: () => toast.ok(v ? t("inbounds.enabled") : t("inbounds.disabled")) })}
                    />
                  </div>
                  <div className="mt-4 flex flex-wrap items-center gap-2">
                    {!i.enabled ? (
                      <Pill tone="off">{t("inbounds.off")}</Pill>
                    ) : i.status === "ok" ? (
                      <Pill tone="ok">{t("inbounds.working")}</Pill>
                    ) : i.status === "error" ? (
                      <Pill tone="bad">{t("inbounds.error")}</Pill>
                    ) : (
                      <Pill tone="off">{t("inbounds.checking")}</Pill>
                    )}
                    {i.shared ? (
                      <span title={t("inbounds.sharedWarn")}>
                        <Pill tone="warn">{t("inbounds.sharedKey")}</Pill>
                      </span>
                    ) : null}
                    {i.dest ? <span className="text-xs text-[var(--ink-500)]">{t("inbounds.maskedAs", { dest: maskedAs(i) })}</span> : null}
                  </div>
                  {i.apps.length > 0 && i.apps.length < 5 ? (
                    <p className="mt-2 text-xs text-[var(--ink-500)]">{t("inbounds.appsLine", { list: i.apps.map((a) => tMaybe(`inbounds.apps.${a}`) ?? a).join(", ") })}</p>
                  ) : null}
                  {i.status === "error" && i.error ? (
                    <p className="mt-3 text-[13px] text-[var(--berry-600)]" role="alert">
                      {listenerError(i.error)}
                    </p>
                  ) : null}
                  <AutoInfo i={i} />
                  <div className="mt-4 flex gap-2 border-t border-[var(--hairline)] pt-4">
                    <Button size="sm" onClick={() => setEditing(i)}>
                      <Pencil size={16} aria-hidden /> {t("inbounds.configure")}
                    </Button>
                    <Button size="sm" variant="danger" onClick={() => setRemoving(i)}>
                      <Trash2 size={16} aria-hidden /> {t("common.delete")}
                    </Button>
                  </div>
                </section>
              ))}
            </div>
          )
        }
      </QueryBoundary>
      <AddDrawer open={adding} onOpenChange={setAdding} nodeId={nodeId} nodeName={multi && node ? nodeLabel(node) : undefined} />
      <EditDrawer inbound={editing} onClose={() => setEditing(null)} />
      <Confirm
        open={!!removing}
        onOpenChange={(v) => !v && setRemoving(null)}
        title={t("inbounds.deleteTitle", { name: removing?.sub_name ?? "" })}
        text={t("inbounds.deleteText")}
        confirm={t("common.delete")}
        danger
        loading={remove.isPending}
        onConfirm={() => removing && remove.mutate(removing.id)}
      />
    </>
  );
}

function MTProtoCard() {
  const mt = useMTProto();
  const qc = useQueryClient();
  const toast = useToast();
  const copy = useCopy();
  const [port, setPort] = useState("8443");
  const [domain, setDomain] = useState("");
  useEffect(() => {
    if (!mt.data) return;
    setPort(String(mt.data.port));
    setDomain(mt.data.domain);
  }, [mt.data?.port, mt.data?.domain]);
  const save = useMutation({
    mutationFn: (body: { enabled?: boolean; port?: number; domain?: string }) =>
      rawApi("/api/v1/mtproto", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }) as Promise<MTProtoView>,
    onSuccess: (data) => {
      qc.setQueryData(qk.mtproto, data);
      toast.ok(t("inbounds.mtproto.saved"));
    },
    onError: (e) => toast.error(errorText(e)),
  });
  const regenerate = useMutation({
    mutationFn: () => rawApi("/api/v1/mtproto/regenerate", { method: "POST" }) as Promise<MTProtoView>,
    onSuccess: (data) => {
      qc.setQueryData(qk.mtproto, data);
      toast.ok(t("inbounds.mtproto.regenerated"));
    },
    onError: (e) => toast.error(errorText(e)),
  });
  if (mt.isPending || !mt.data) return <Skeleton className="mb-4 block" style={{ height: 220, borderRadius: 20 }} />;
  const data = mt.data;
  const tone = data.status === "running" ? "ok" : data.status === "error" ? "bad" : data.enabled ? "warn" : "off";
  return (
    <section className="card glass mb-4 reveal">
      <div className="card-head">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="card-title">{t("inbounds.mtproto.title")}</h2>
            <Pill tone={tone}>{t(`inbounds.mtproto.status.${data.status}`)}</Pill>
          </div>
          <div className="card-sub">{t("inbounds.mtproto.subtitle")}</div>
        </div>
        <Switch
          checked={data.enabled}
          label={t("inbounds.mtproto.enabled")}
          disabled={save.isPending}
          onChange={(enabled) => save.mutate({ enabled, port: Number(port), domain })}
        />
      </div>
      <div className="grid gap-3 md:grid-cols-[160px_1fr]">
        <Field label={t("inbounds.mtproto.port")} htmlFor="mtproto-port">
          <input id="mtproto-port" className="input" inputMode="numeric" value={port} onChange={(e) => setPort(e.target.value.replace(/\D/g, "").slice(0, 5))} />
        </Field>
        <Field label={t("inbounds.mtproto.domain")} htmlFor="mtproto-domain" hint={t("inbounds.mtproto.domainHint")}>
          <input id="mtproto-domain" className="input mono" value={domain} onChange={(e) => setDomain(e.target.value)} placeholder="www.cloudflare.com" />
        </Field>
      </div>
      <div className="flex flex-wrap gap-2">
        <Button variant="primary" loading={save.isPending} disabled={!port || !domain} onClick={() => save.mutate({ port: Number(port), domain })}>
          {t("common.save")}
        </Button>
        <Button loading={regenerate.isPending} onClick={() => regenerate.mutate()}>
          <RefreshCw size={16} aria-hidden /> {t("inbounds.mtproto.regenerate")}
        </Button>
      </div>
      {data.link ? (
        <div className="panel-soft mt-4 p-3">
          <div className="mb-2 text-xs font-semibold text-[var(--ink-500)]">{t("inbounds.mtproto.link")}</div>
          <code className="mono block w-full break-all">{data.link}</code>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button size="sm" onClick={() => void copy(data.link, t("inbounds.mtproto.copied"))}>
              <Copy size={16} aria-hidden /> {t("common.copyLink")}
            </Button>
            <a className="btn btn-glass btn-sm" href={data.link} target="_blank" rel="noreferrer">
              <Send size={16} aria-hidden /> {t("inbounds.mtproto.open")}
            </a>
          </div>
        </div>
      ) : null}
      {data.status === "error" ? <p className="mt-3 text-[13px] text-[var(--berry-600)]">{t("inbounds.mtproto.error")}</p> : null}
    </section>
  );
}

/** What the automatic fixes see and last did for a connection. */
function AutoInfo({ i }: { i: Inbound }) {
  const a = i.auto;
  return (
    <>
      {i.enabled && a.cut_off ? (
        <div className="mt-3 flex flex-col items-start gap-1.5" role="status">
          <Pill tone="warn">{a.reached ? t("inbounds.cutOffOf", { n: a.blocked, total: a.blocked + a.reached }) : t("inbounds.cutOff", { n: a.blocked })}</Pill>
          {a.stuck ? <span className="text-xs text-[var(--ink-500)]">{t(`inbounds.stuck.${a.stuck}`)}</span> : null}
        </div>
      ) : null}
      {i.enabled && a.target_ok === false ? (
        <p className="mt-3 text-[13px] text-[var(--berry-600)]" role="alert">
          {t("inbounds.targetDown", { reason: tMaybe(`inbounds.targetErr.${a.target_error ?? ""}`) ?? a.target_error ?? "" })}
        </p>
      ) : null}
      {a.last ? (
        <p className="mt-3 text-xs text-[var(--ink-500)]">
          {t(a.last.kind === "port" ? "inbounds.lastPort" : "inbounds.lastSni", { old: a.last.old, new: a.last.new, ago: ago(a.last.at) })} · {t(`inbounds.reason.${a.last.reason}`)}
        </p>
      ) : null}
    </>
  );
}
