import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";
import { type FormEvent } from "react";
import { api, errorText, unwrap, type Schemas } from "../../../api/client";
import { qk, usePaymentSettings } from "../../../api/hooks";
import { useToast } from "../../../components/toast";
import { Button, ErrorState, Field, Skeleton } from "../../../components/ui";
import { Switch } from "../../../components/switch";
import { LOCALES, t } from "../../../i18n";
import { useDraft } from "../../../lib/draft";
import { fieldErrors } from "../../../lib/fields";
import { useSaveSettings } from "./shared";

export function ServerCard({ s }: { s: Schemas["SettingsView"] }) {
  const save = useSaveSettings();
  // Saving another card replaces `s`: what is typed here stays.
  const { draft: form, setDraft: setForm } = useDraft({ public_host: s.public_host, domain: s.domain, quiet_hour_utc: String(s.quiet_hour_utc) });
  const errors = fieldErrors(save.error);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    save.mutate({ public_host: form.public_host, domain: form.domain, quiet_hour_utc: Number(form.quiet_hour_utc) });
  };
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));
  return (
    <section className="card glass reveal">
      <form onSubmit={submit} noValidate>
        <div className="card-head">
          <h2 className="card-title">{t("settings.server")}</h2>
        </div>
        <Field label={t("settings.host")} htmlFor="s-host" hint={t("settings.hostHint")} error={errors.public_host}>
          <input id="s-host" className="input mono" value={form.public_host} onChange={set("public_host")} aria-invalid={!!errors.public_host} />
        </Field>
        <Field label={t("settings.domain")} htmlFor="s-domain" hint={t("settings.domainHint")} error={errors.domain}>
          <input id="s-domain" className="input mono" value={form.domain} onChange={set("domain")} placeholder="vpn.example.com" aria-invalid={!!errors.domain} />
        </Field>
        <Field label={t("settings.quietHour")} htmlFor="s-quiet" hint={t("settings.quietHourHint")}>
          <input id="s-quiet" className="input max-w-[100px]" inputMode="numeric" value={form.quiet_hour_utc} onChange={set("quiet_hour_utc")} />
        </Field>
        <Button type="submit" variant="primary" loading={save.isPending}>
          {t("common.save")}
        </Button>
      </form>
    </section>
  );
}

/** What visitors get until they pick a language; the header's switch is this browser's own. */
export function LanguageCard({ s }: { s: Schemas["SettingsView"] }) {
  const save = useSaveSettings();
  const options = [
    { id: "auto", label: t("settings.langAuto") },
    ...LOCALES.map((l) => ({ id: l.id, label: l.label, lang: l.id })),
  ] as const;
  const current = (save.isPending && save.variables.default_lang) || s.default_lang;
  return (
    <section className="card glass reveal" style={{ "--i": 2 } as React.CSSProperties}>
      <div className="card-head">
        <div>
          <h2 className="card-title">{t("settings.lang")}</h2>
          <div className="card-sub">{t("settings.langSub")}</div>
        </div>
      </div>
      <div className="grid gap-2 sm:grid-cols-3" role="radiogroup" aria-label={t("settings.lang")} aria-busy={save.isPending}>
        {options.map((o) => (
          <button
            key={o.id}
            type="button"
            role="radio"
            aria-checked={current === o.id}
            className="opt"
            lang={"lang" in o ? o.lang : undefined}
            disabled={save.isPending}
            onClick={() => o.id !== s.default_lang && save.mutate({ default_lang: o.id })}
          >
            <span className="font-semibold">{o.label}</span>
          </button>
        ))}
      </div>
      <p className="mt-3 text-xs text-[var(--ink-500)]">{t("settings.langNote")}</p>
    </section>
  );
}

/** Global switches of the automatic fixes; each connection can opt out in its settings. */
export function AutoCard({ s }: { s: Schemas["SettingsView"] }) {
  const save = useSaveSettings();
  const rows = [
    { key: "auto_port", title: t("settings.autoPort"), sub: t("settings.autoPortSub"), on: s.auto_port },
    { key: "auto_sni", title: t("settings.autoSni"), sub: t("settings.autoSniSub"), on: s.auto_sni },
  ] as const;
  return (
    <section className="card glass reveal" style={{ "--i": 3 } as React.CSSProperties}>
      <div className="card-head">
        <div>
          <h2 className="card-title">{t("settings.auto")}</h2>
          <div className="card-sub">{t("settings.autoSub")}</div>
        </div>
      </div>
      <ul className="row-list">
        {rows.map((r) => (
          <li key={r.key} className="flex items-start justify-between gap-4 py-3">
            <div className="min-w-0">
              <div className="text-[13px] font-medium">{r.title}</div>
              <div className="mt-1 text-xs text-[var(--ink-500)]">{r.sub}</div>
            </div>
            <Switch checked={r.on} label={r.title} disabled={save.isPending} onChange={(v) => save.mutate({ [r.key]: v })} />
          </li>
        ))}
      </ul>
      <p className="mt-3 text-xs text-[var(--ink-500)]">{t("settings.autoNote")}</p>
    </section>
  );
}

// The switch for selling at all. Off, Payments leaves the menu; the page stays reachable
// from here for the history.
export function SalesCard() {
  const qc = useQueryClient();
  const toast = useToast();
  const ps = usePaymentSettings();
  const save = useMutation({
    mutationFn: (enabled: boolean) => unwrap(api.PATCH("/api/v1/payments/settings", { body: { enabled } })),
    onSuccess: (v) => {
      qc.setQueryData(qk.paymentSettings, v);
      toast.ok(v.enabled ? t("settings.salesOnToast") : t("settings.salesOffToast"));
    },
    onError: (e) => toast.error(errorText(e)),
  });
  const on = ps.data?.enabled === true;
  return (
    <section className="card glass reveal" style={{ "--i": 5 } as React.CSSProperties}>
      <div className="card-head">
        <div>
          <h2 className="card-title">{t("settings.sales")}</h2>
          <div className="card-sub">{t("settings.salesSub")}</div>
        </div>
        {ps.isPending ? (
          <Skeleton style={{ width: 40, height: 24, borderRadius: 12 }} />
        ) : ps.isError && !ps.data ? null : (
          <Switch checked={on} label={t("settings.sales")} disabled={save.isPending} onChange={(v) => save.mutate(v)} />
        )}
      </div>
      {ps.isError && !ps.data ? (
        <ErrorState text={errorText(ps.error)} onRetry={() => void ps.refetch()} />
      ) : ps.data ? (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="min-w-0 flex-1 text-xs text-[var(--ink-500)]">{on ? t("settings.salesOnNote") : t("settings.salesOffNote")}</p>
          <Link to="/payments" className="btn btn-glass btn-sm">
            {t("settings.openPayments")} <ChevronRight size={16} aria-hidden />
          </Link>
        </div>
      ) : null}
    </section>
  );
}

