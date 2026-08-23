"use client";

import {
  ArrowRight,
  AudioLines,
  Bot,
  CalendarRange,
  Check,
  CheckCircle2,
  ChevronRight,
  CircleHelp,
  Clipboard,
  Clock3,
  FileText,
  GitBranch,
  Link2,
  LoaderCircle,
  MessageSquareText,
  Mic,
  Pencil,
  Quote,
  RotateCcw,
  Search,
  ShieldCheck,
  Sparkles,
  Undo2,
  UserCheck,
  X,
} from "lucide-react";
import {
  type FormEvent,
  type KeyboardEvent,
  useEffect,
  useRef,
  useState,
} from "react";
import styles from "./memory-demo.module.css";

type Stage = "capture" | "review" | "thread" | "reuse" | "weekly";
type SourceKind = "voice" | "claude" | "interview" | "text";

type Source = {
  id: string;
  kind: SourceKind;
  label: string;
  title: string;
  time: string;
  date: string;
  quote: string;
  context: string;
};

const stages: Array<{
  id: Stage;
  label: string;
  description: string;
}> = [
  { id: "capture", label: "原始记录", description: "不分类，先保存" },
  { id: "review", label: "待确认", description: "AI 只提出候选" },
  { id: "thread", label: "思路线", description: "保留判断变化" },
  { id: "reuse", label: "任务前调用", description: "把依据带回来" },
  { id: "weekly", label: "周回顾", description: "看变化与反证" },
];

const initialSources: Source[] = [
  {
    id: "voice-pricing",
    kind: "voice",
    label: "语音",
    title: "散步时的想法",
    time: "09:18",
    date: "今天",
    quote:
      "定价先不要做免费层。早期应该用年付去验证，愿意留下的人是否真的会付费。",
    context: "合成语音示例。转写与置信度仅用于演示，不读取真实录音。",
  },
  {
    id: "claude-pricing",
    kind: "claude",
    label: "Claude",
    title: "商业模式讨论",
    time: "14:42",
    date: "今天",
    quote:
      "如果目标是验证决策记忆，免费层会把激活和留存混在一起。先做真实收费测试更容易得到明确答案。",
    context: "通过分享菜单导入，保留原对话 ID 和消息位置。",
  },
  {
    id: "interview-export",
    kind: "interview",
    label: "访谈",
    title: "与示例用户的访谈",
    time: "17:06",
    date: "今天",
    quote:
      "我愿意为它付钱，但前提是我能看到每条结论来自哪里，而且随时可以完整导出。",
    context: "用户手动标记为重要，人物归属由用户确认。",
  },
];

const initialDecisionTitle = "先测试年付，不做免费层";
const initialDecisionReason =
  "先用真实付费验证决策记忆是否不可替代，避免免费用户稀释早期信号。";

const stageIndex = (stage: Stage) =>
  stages.findIndex((item) => item.id === stage);

const sourceIcon = {
  voice: Mic,
  claude: MessageSquareText,
  interview: UserCheck,
  text: FileText,
};

const stageMeta: Record<
  Stage,
  { kicker: string; title: string; description: string }
> = {
  capture: {
    kicker: "今天的输入",
    title: "先把碎片留下",
    description: "不用分类，也不用当场想清楚。DayPage 只保存当时实际发生的内容。",
  },
  review: {
    kicker: "待确认记忆",
    title: "今天有一个决定值得确认",
    description: "原话和 AI 推断分开显示。确认之前，它不会进入长期记忆。",
  },
  thread: {
    kicker: "定价策略",
    title: "一条判断是如何形成的",
    description: "思路线保留变化、依据与冲突，不把过去改写成一个过度连贯的故事。",
  },
  reuse: {
    kicker: "任务前调用",
    title: "重新讨论时，不必从零开始",
    description: "只调用已经确认的记忆，并把原始依据一起交给当前任务。",
  },
  weekly: {
    kicker: "本周决策回顾",
    title: "看见变化，而不是再读一遍摘要",
    description: "回顾聚焦决定、反证和未闭环问题，最后的判断仍由你完成。",
  },
};

function SourceIcon({ kind }: { kind: SourceKind }) {
  const Icon = sourceIcon[kind];
  return <Icon aria-hidden="true" size={17} strokeWidth={1.8} />;
}

export function DecisionMemoryDemo() {
  const [stage, setStage] = useState<Stage>("capture");
  const [furthestStage, setFurthestStage] = useState(0);
  const [sources, setSources] = useState<Source[]>(initialSources);
  const [draft, setDraft] = useState("");
  const [isCompiling, setIsCompiling] = useState(false);
  const [decisionTitle, setDecisionTitle] = useState(initialDecisionTitle);
  const [decisionReason, setDecisionReason] = useState(initialDecisionReason);
  const [draftDecisionTitle, setDraftDecisionTitle] = useState(
    initialDecisionTitle,
  );
  const [draftDecisionReason, setDraftDecisionReason] = useState(
    initialDecisionReason,
  );
  const [isEditing, setIsEditing] = useState(false);
  const [isConfirmed, setIsConfirmed] = useState(false);
  const [wasEdited, setWasEdited] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [selectedSource, setSelectedSource] = useState<Source | null>(null);
  const [isRetrieving, setIsRetrieving] = useState(false);
  const [contextReady, setContextReady] = useState(false);
  const [copied, setCopied] = useState(false);
  const [weeklyResolution, setWeeklyResolution] = useState<
    "kept" | "review" | null
  >(null);
  const [toast, setToast] = useState<string | null>(null);
  const dialogCloseRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  const sourceTriggerRef = useRef<HTMLElement | null>(null);
  const workspaceHeadingRef = useRef<HTMLHeadingElement>(null);

  const currentStageIndex = stageIndex(stage);
  useEffect(() => {
    if (!selectedSource) return;
    dialogCloseRef.current?.focus();
  }, [selectedSource]);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(null), 2800);
    return () => window.clearTimeout(timer);
  }, [toast]);

  function visitStage(nextStage: Stage) {
    const nextIndex = stageIndex(nextStage);
    setStage(nextStage);
    setFurthestStage((current) => Math.max(current, nextIndex));
    const reduceMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    window.scrollTo({ top: 0, behavior: reduceMotion ? "auto" : "smooth" });
    window.requestAnimationFrame(() => {
      workspaceHeadingRef.current?.focus({ preventScroll: true });
    });
  }

  function resetDemo() {
    setStage("capture");
    setFurthestStage(0);
    setSources(initialSources);
    setDraft("");
    setIsCompiling(false);
    setDecisionTitle(initialDecisionTitle);
    setDecisionReason(initialDecisionReason);
    setDraftDecisionTitle(initialDecisionTitle);
    setDraftDecisionReason(initialDecisionReason);
    setIsEditing(false);
    setIsConfirmed(false);
    setWasEdited(false);
    setDismissed(false);
    setSelectedSource(null);
    setIsRetrieving(false);
    setContextReady(false);
    setCopied(false);
    setWeeklyResolution(null);
    setToast("演示已重置");
  }

  function addSource(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = draft.trim();
    if (!body) return;

    setSources((current) => [
      ...current,
      {
        id: `manual-${Date.now()}`,
        kind: "text",
        label: "文字",
        title: "刚刚补充",
        time: new Intl.DateTimeFormat("zh-CN", {
          hour: "2-digit",
          minute: "2-digit",
          hour12: false,
        }).format(new Date()),
        date: "今天",
        quote: body,
        context: "本次演示中手动添加的原始文字，没有经过 AI 改写。",
      },
    ]);
    setDraft("");
    setToast("原始记录已保存");
  }

  function compileSources() {
    setIsCompiling(true);
    window.setTimeout(() => {
      setIsCompiling(false);
      setDismissed(false);
      visitStage("review");
    }, 900);
  }

  function confirmDecision() {
    setIsConfirmed(true);
    setIsEditing(false);
    setToast("已确认，后续推理可以使用");
    visitStage("thread");
  }

  function startDecisionEdit() {
    setDraftDecisionTitle(decisionTitle);
    setDraftDecisionReason(decisionReason);
    setIsEditing(true);
  }

  function saveDecision(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draftDecisionTitle.trim() || !draftDecisionReason.trim()) return;
    setDecisionTitle(draftDecisionTitle.trim());
    setDecisionReason(draftDecisionReason.trim());
    setWasEdited(true);
    setIsEditing(false);
    setToast("修改已保存，原始证据保持不变");
  }

  function openSource(source: Source) {
    sourceTriggerRef.current =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;
    setSelectedSource(source);
  }

  function closeSource() {
    setSelectedSource(null);
    window.requestAnimationFrame(() => sourceTriggerRef.current?.focus());
  }

  function retrieveContext() {
    setIsRetrieving(true);
    window.setTimeout(() => {
      setIsRetrieving(false);
      setContextReady(true);
      setToast("已找到一条已确认决定");
    }, 760);
  }

  async function copyContext() {
    const context = [
      `已确认决定：${decisionTitle}`,
      `理由：${decisionReason}`,
      "反证：用户愿意付费，但要求来源透明并支持完整导出。",
      "来源：今天 09:18 语音；14:42 Claude 对话；17:06 用户访谈。",
    ].join("\n");

    try {
      await navigator.clipboard.writeText(context);
      setCopied(true);
      setToast("上下文已复制，记为一次复用");
    } catch {
      setCopied(true);
      setToast("已在演示中记录一次复用");
    }

    window.setTimeout(() => visitStage("weekly"), 650);
  }

  function handleDialogKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") {
      event.preventDefault();
      closeSource();
      return;
    }

    if (event.key !== "Tab" || !dialogRef.current) return;
    const focusable = Array.from(
      dialogRef.current.querySelectorAll<HTMLElement>(
        'button, [href], input, textarea, select, [tabindex]:not([tabindex="-1"])',
      ),
    ).filter((element) => !element.hasAttribute("disabled"));
    const first = focusable[0];
    const last = focusable.at(-1);
    if (!first || !last) return;

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  return (
    <main id="main" lang="zh-CN" className={styles.page}>
      <header className={styles.topbar}>
        <div className={styles.brand}>
          <span className={styles.brandMark} aria-hidden="true">
            D
          </span>
          <span>DayPage</span>
          <span className={styles.brandContext}>决策记忆演示</span>
          <span className={styles.sampleBadge}>合成示例</span>
        </div>
        <button className={styles.resetButton} type="button" onClick={resetDemo}>
          <RotateCcw aria-hidden="true" size={15} strokeWidth={1.8} />
          重置演示
        </button>
      </header>

      <div className={styles.shell} aria-hidden={selectedSource ? true : undefined}>
        <aside className={styles.sidebar} aria-label="演示进度">
          <div className={styles.sidebarIntro}>
            <p>一条完整链路</p>
            <strong>从碎片到可复用的决定</strong>
          </div>
          <nav className={styles.stageNav}>
            {stages.map((item, index) => {
              const isActive = item.id === stage;
              const isComplete = index < currentStageIndex || index < furthestStage;
              const isAvailable = index <= furthestStage || isActive;

              return (
                <button
                  key={item.id}
                  type="button"
                  className={`${styles.stageButton} ${
                    isActive ? styles.stageButtonActive : ""
                  }`}
                  disabled={!isAvailable}
                  aria-current={isActive ? "step" : undefined}
                  onClick={() => visitStage(item.id)}
                >
                  <span className={styles.stageState} aria-hidden="true">
                    {isComplete ? <Check size={14} strokeWidth={2.2} /> : index + 1}
                  </span>
                  <span>
                    <strong>{item.label}</strong>
                    <small>{item.description}</small>
                  </span>
                  {isActive && (
                    <ChevronRight
                      className={styles.stageChevron}
                      aria-hidden="true"
                      size={16}
                      strokeWidth={1.8}
                    />
                  )}
                </button>
              );
            })}
          </nav>
          <div className={styles.trustNote}>
            <ShieldCheck aria-hidden="true" size={18} strokeWidth={1.7} />
            <p>
              <strong>信任契约</strong>
              原始记录永不被 AI 覆盖。推断只有确认后才成为长期记忆。
            </p>
          </div>
        </aside>

        <section className={styles.workspace}>
          <div className={styles.workspaceHeader}>
            <p>{stageMeta[stage].kicker}</p>
            <h1 ref={workspaceHeadingRef} tabIndex={-1}>
              {stageMeta[stage].title}
            </h1>
            <span>{stageMeta[stage].description}</span>
          </div>

          {stage === "capture" && (
            <CaptureStage
              sources={sources}
              draft={draft}
              isCompiling={isCompiling}
              onDraftChange={setDraft}
              onAddSource={addSource}
              onCompile={compileSources}
              onOpenSource={openSource}
            />
          )}

          {stage === "review" && (
            <ReviewStage
              sources={sources}
              decisionTitle={decisionTitle}
              decisionReason={decisionReason}
              draftDecisionTitle={draftDecisionTitle}
              draftDecisionReason={draftDecisionReason}
              isEditing={isEditing}
              isConfirmed={isConfirmed}
              wasEdited={wasEdited}
              dismissed={dismissed}
              onDecisionTitleChange={setDraftDecisionTitle}
              onDecisionReasonChange={setDraftDecisionReason}
              onEdit={startDecisionEdit}
              onCancelEdit={() => setIsEditing(false)}
              onSaveEdit={saveDecision}
              onConfirm={confirmDecision}
              onDismiss={() => setDismissed(true)}
              onUndoDismiss={() => setDismissed(false)}
              onOpenSource={openSource}
            />
          )}

          {stage === "thread" && (
            <ThreadStage
              title={decisionTitle}
              reason={decisionReason}
              wasEdited={wasEdited}
              onContinue={() => visitStage("reuse")}
              onOpenSource={() => openSource(sources[0])}
            />
          )}

          {stage === "reuse" && (
            <ReuseStage
              title={decisionTitle}
              reason={decisionReason}
              isConfirmed={isConfirmed}
              isRetrieving={isRetrieving}
              contextReady={contextReady}
              copied={copied}
              onRetrieve={retrieveContext}
              onCopy={copyContext}
              onOpenSource={() => openSource(sources[0])}
            />
          )}

          {stage === "weekly" && (
            <WeeklyStage
              title={decisionTitle}
              sourceCount={sources.length}
              resolution={weeklyResolution}
              onResolve={setWeeklyResolution}
              onRestart={resetDemo}
              onOpenSource={openSource}
              sources={sources}
            />
          )}
        </section>
      </div>

      <div
        className={styles.principles}
        aria-label="产品原则"
        aria-hidden={selectedSource ? true : undefined}
      >
        <span>合成示例，不读取或保存真实 vault</span>
        <span>原始记录是证据</span>
        <span>AI 输出是待确认解释</span>
        <span>外部动作需要批准</span>
      </div>

      {selectedSource && (
        <div
          className={styles.dialogBackdrop}
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeSource();
          }}
          onKeyDown={handleDialogKeyDown}
        >
          <div
            ref={dialogRef}
            className={styles.sourceDialog}
            role="dialog"
            aria-modal="true"
            aria-labelledby="source-dialog-title"
          >
            <div className={styles.dialogHeader}>
              <div className={styles.sourceIdentity}>
                <span className={styles.sourceIcon}>
                  <SourceIcon kind={selectedSource.kind} />
                </span>
                <div>
                  <p>{selectedSource.label}原文</p>
                  <h2 id="source-dialog-title">{selectedSource.title}</h2>
                </div>
              </div>
              <button
                ref={dialogCloseRef}
                type="button"
                className={styles.iconButton}
                aria-label="关闭原文"
                onClick={closeSource}
              >
                <X aria-hidden="true" size={18} strokeWidth={1.8} />
              </button>
            </div>
            <blockquote className={styles.fullQuote}>
              “{selectedSource.quote}”
            </blockquote>
            <dl className={styles.sourceMetadata}>
              <div>
                <dt>记录时间</dt>
                <dd>
                  {selectedSource.date} {selectedSource.time}
                </dd>
              </div>
              <div>
                <dt>原始来源</dt>
                <dd>{selectedSource.label}</dd>
              </div>
              <div>
                <dt>AI 权限</dt>
                <dd>仅用于本次编译</dd>
              </div>
            </dl>
            <p className={styles.sourceContext}>{selectedSource.context}</p>
            <div className={styles.untouchedReceipt}>
              <ShieldCheck aria-hidden="true" size={16} strokeWidth={1.8} />
              这是原始证据。用户修改推断时，它不会被覆盖。
            </div>
          </div>
        </div>
      )}

      {toast && (
        <div className={styles.toast} role="status" aria-live="polite">
          <CheckCircle2 aria-hidden="true" size={17} strokeWidth={2} />
          {toast}
        </div>
      )}
    </main>
  );
}

function CaptureStage({
  sources,
  draft,
  isCompiling,
  onDraftChange,
  onAddSource,
  onCompile,
  onOpenSource,
}: {
  sources: Source[];
  draft: string;
  isCompiling: boolean;
  onDraftChange: (value: string) => void;
  onAddSource: (event: FormEvent<HTMLFormElement>) => void;
  onCompile: () => void;
  onOpenSource: (source: Source) => void;
}) {
  return (
    <div className={styles.stageContent}>
      <div className={styles.captureGrid}>
        <div className={styles.sourceList}>
          {sources.map((source) => (
            <button
              type="button"
              className={styles.sourceRow}
              key={source.id}
              onClick={() => onOpenSource(source)}
            >
              <span className={styles.sourceIcon}>
                <SourceIcon kind={source.kind} />
              </span>
              <span className={styles.sourceBody}>
                <span className={styles.sourceTopline}>
                  <strong>{source.title}</strong>
                  <time>{source.time}</time>
                </span>
                <span className={styles.sourceQuote}>{source.quote}</span>
                <span className={styles.sourceFooter}>
                  {source.label}
                  <Link2 aria-hidden="true" size={13} strokeWidth={1.8} />
                  查看原文
                </span>
              </span>
            </button>
          ))}
        </div>

        <form className={styles.captureForm} onSubmit={onAddSource}>
          <div className={styles.captureFormHeading}>
            <AudioLines aria-hidden="true" size={20} strokeWidth={1.7} />
            <div>
              <strong>补充一条真实想法</strong>
              <span>可选。它会作为新的原始证据加入演示。</span>
            </div>
          </div>
          <label htmlFor="demo-capture">记录内容</label>
          <textarea
            id="demo-capture"
            value={draft}
            onChange={(event) => onDraftChange(event.target.value)}
            placeholder="例如：我担心年付会让试用门槛太高。"
            rows={5}
          />
          <button
            type="submit"
            className={styles.secondaryButton}
            disabled={!draft.trim()}
          >
            保存原始记录
          </button>
        </form>
      </div>

      <div className={styles.primaryActionRow}>
        <div>
          <Sparkles aria-hidden="true" size={18} strokeWidth={1.7} />
          <p>
            <strong>{sources.length} 条证据已准备</strong>
            编译只生成候选，不会写入长期记忆。
          </p>
        </div>
        <button
          type="button"
          className={styles.primaryButton}
          disabled={isCompiling}
          onClick={onCompile}
        >
          {isCompiling ? (
            <>
              <LoaderCircle
                className={styles.spinner}
                aria-hidden="true"
                size={17}
                strokeWidth={1.9}
              />
              正在寻找决定
            </>
          ) : (
            <>
              编译待确认记忆
              <ArrowRight aria-hidden="true" size={17} strokeWidth={1.8} />
            </>
          )}
        </button>
      </div>
    </div>
  );
}

function ReviewStage({
  sources,
  decisionTitle,
  decisionReason,
  draftDecisionTitle,
  draftDecisionReason,
  isEditing,
  isConfirmed,
  wasEdited,
  dismissed,
  onDecisionTitleChange,
  onDecisionReasonChange,
  onEdit,
  onCancelEdit,
  onSaveEdit,
  onConfirm,
  onDismiss,
  onUndoDismiss,
  onOpenSource,
}: {
  sources: Source[];
  decisionTitle: string;
  decisionReason: string;
  draftDecisionTitle: string;
  draftDecisionReason: string;
  isEditing: boolean;
  isConfirmed: boolean;
  wasEdited: boolean;
  dismissed: boolean;
  onDecisionTitleChange: (value: string) => void;
  onDecisionReasonChange: (value: string) => void;
  onEdit: () => void;
  onCancelEdit: () => void;
  onSaveEdit: (event: FormEvent<HTMLFormElement>) => void;
  onConfirm: () => void;
  onDismiss: () => void;
  onUndoDismiss: () => void;
  onOpenSource: (source: Source) => void;
}) {
  const unclassifiedSources = sources.slice(3);

  if (dismissed) {
    return (
      <div className={styles.emptyState}>
        <CircleHelp aria-hidden="true" size={26} strokeWidth={1.6} />
        <h2>这条候选不会进入长期记忆</h2>
        <p>原始记录仍然保留。忽略 AI 推断不会删除用户当时说过的话。</p>
        <button
          type="button"
          className={styles.secondaryButton}
          onClick={onUndoDismiss}
        >
          <Undo2 aria-hidden="true" size={16} strokeWidth={1.8} />
          恢复候选
        </button>
      </div>
    );
  }

  return (
    <div className={styles.stageContent}>
      <article className={styles.decisionCard}>
        <div className={styles.cardHeader}>
          <div className={styles.cardType}>
            <Bot aria-hidden="true" size={17} strokeWidth={1.7} />
            <span>{isConfirmed ? "已确认决定版本" : "AI 提出的决定候选"}</span>
          </div>
          <span className={styles.proposedStatus}>
            {isConfirmed ? "已确认" : wasEdited ? "用户已修改" : "待确认"}
          </span>
        </div>

        {isEditing ? (
          <form className={styles.editForm} onSubmit={onSaveEdit}>
            <div>
              <label htmlFor="decision-title">决定</label>
              <input
                id="decision-title"
                value={draftDecisionTitle}
                onChange={(event) => onDecisionTitleChange(event.target.value)}
                autoFocus
              />
            </div>
            <div>
              <label htmlFor="decision-reason">理由</label>
              <textarea
                id="decision-reason"
                value={draftDecisionReason}
                onChange={(event) => onDecisionReasonChange(event.target.value)}
                rows={4}
              />
            </div>
            <p className={styles.editHelper}>
              修改只影响这条 AI 推断。下面的原始证据保持不变。
            </p>
            <div className={styles.editActions}>
              <button
                type="button"
                className={styles.ghostButton}
                onClick={onCancelEdit}
              >
                取消
              </button>
              <button type="submit" className={styles.primaryButton}>
                保存修改
              </button>
            </div>
          </form>
        ) : (
          <>
            <div className={styles.decisionHeading}>
              <h2>{decisionTitle}</h2>
              <p>{decisionReason}</p>
            </div>

            <div className={styles.aiObservation}>
              <Sparkles aria-hidden="true" size={17} strokeWidth={1.7} />
              <p>
                <strong>为什么现在出现</strong>
                今天的语音和 Claude 对话表达了同一方向，访谈又补充了一个重要前提。
                {unclassifiedSources.length > 0 &&
                  " 你刚补充的内容仍保持为原始证据，不会被强行归入这个候选。"}
              </p>
            </div>
          </>
        )}

        {!isEditing && (
          <div className={styles.evidenceSection}>
            <div className={styles.sectionHeading}>
              <h3>支持这个判断的证据</h3>
              <span>2 条</span>
            </div>
            <div className={styles.evidenceGrid}>
              {sources.slice(0, 2).map((source) => (
                <button
                  type="button"
                  className={styles.evidenceButton}
                  key={source.id}
                  onClick={() => onOpenSource(source)}
                >
                  <Quote aria-hidden="true" size={16} strokeWidth={1.7} />
                  <span>“{source.quote}”</span>
                  <small>
                    {source.label}，{source.time}
                  </small>
                </button>
              ))}
            </div>

            <div className={styles.counterEvidence}>
              <div>
                <Search aria-hidden="true" size={17} strokeWidth={1.8} />
                <strong>需要保留的反证</strong>
              </div>
              <p>用户愿意付费，但把来源透明和完整导出视为前提。</p>
              <button type="button" onClick={() => onOpenSource(sources[2])}>
                查看访谈原文
                <ArrowRight aria-hidden="true" size={14} strokeWidth={1.8} />
              </button>
            </div>

            {unclassifiedSources.map((source) => (
              <div className={styles.unclassifiedEvidence} key={source.id}>
                <div>
                  <FileText aria-hidden="true" size={17} strokeWidth={1.8} />
                  <strong>新证据暂未归类</strong>
                </div>
                <p>“{source.quote}”</p>
                <button type="button" onClick={() => onOpenSource(source)}>
                  查看原始记录
                  <ArrowRight aria-hidden="true" size={14} strokeWidth={1.8} />
                </button>
              </div>
            ))}
          </div>
        )}
      </article>

      {!isEditing && isConfirmed && (
        <div className={styles.reviewActions}>
          <button
            type="button"
            className={styles.primaryButton}
            onClick={onConfirm}
          >
            <CheckCircle2 aria-hidden="true" size={16} strokeWidth={2} />
            返回已确认思路线
          </button>
        </div>
      )}

      {!isEditing && !isConfirmed && (
        <div className={styles.reviewActions}>
          <button
            type="button"
            className={styles.ghostButton}
            onClick={onDismiss}
          >
            忽略
          </button>
          <button
            type="button"
            className={styles.secondaryButton}
            onClick={onEdit}
          >
            <Pencil aria-hidden="true" size={15} strokeWidth={1.8} />
            修改
          </button>
          <button
            type="button"
            className={styles.primaryButton}
            onClick={onConfirm}
          >
            <Check aria-hidden="true" size={16} strokeWidth={2} />
            确认进入思路线
          </button>
        </div>
      )}
    </div>
  );
}

function ThreadStage({
  title,
  reason,
  wasEdited,
  onContinue,
  onOpenSource,
}: {
  title: string;
  reason: string;
  wasEdited: boolean;
  onContinue: () => void;
  onOpenSource: () => void;
}) {
  return (
    <div className={styles.stageContent}>
      <article className={styles.threadCard}>
        <div className={styles.threadTop}>
          <div>
            <span className={styles.confirmedLabel}>
              <CheckCircle2 aria-hidden="true" size={15} strokeWidth={2} />
              已确认
            </span>
            <h2>DayPage 定价策略</h2>
          </div>
          <span className={styles.threadMeta}>3 次变化，5 条证据</span>
        </div>

        <div className={styles.timeline}>
          <div className={styles.timelineItem}>
            <time>7 月 18 日</time>
            <div>
              <h3>先不讨论价格</h3>
              <p>当时更关心能否稳定完成每日编译。</p>
            </div>
          </div>
          <div className={styles.timelineItem}>
            <time>7 月 27 日</time>
            <div>
              <h3>付费必须验证不可替代性</h3>
              <p>开始把“找回一个遗忘决定”视为核心价值时刻。</p>
            </div>
          </div>
          <div className={`${styles.timelineItem} ${styles.timelineCurrent}`}>
            <time>今天</time>
            <div>
              <div className={styles.currentDecisionTopline}>
                <h3>{title}</h3>
                {wasEdited && <span>用户修正</span>}
              </div>
              <p>{reason}</p>
              <button type="button" onClick={onOpenSource}>
                <Link2 aria-hidden="true" size={14} strokeWidth={1.8} />
                回到原始语音
              </button>
            </div>
          </div>
        </div>

        <div className={styles.constraintNote}>
          <ShieldCheck aria-hidden="true" size={18} strokeWidth={1.7} />
          <p>
            <strong>确认后的约束</strong>
            后续系统只能把这条记忆描述为一次待验证的定价决定，不能把它推断成永久偏好。
          </p>
        </div>
      </article>

      <div className={styles.primaryActionRow}>
        <div>
          <GitBranch aria-hidden="true" size={18} strokeWidth={1.7} />
          <p>
            <strong>不是覆盖旧结论</strong>
            新判断作为一个带时间和来源的版本加入。
          </p>
        </div>
        <button
          type="button"
          className={styles.primaryButton}
          onClick={onContinue}
        >
          模拟下次讨论
          <ArrowRight aria-hidden="true" size={17} strokeWidth={1.8} />
        </button>
      </div>
    </div>
  );
}

function ReuseStage({
  title,
  reason,
  isConfirmed,
  isRetrieving,
  contextReady,
  copied,
  onRetrieve,
  onCopy,
  onOpenSource,
}: {
  title: string;
  reason: string;
  isConfirmed: boolean;
  isRetrieving: boolean;
  contextReady: boolean;
  copied: boolean;
  onRetrieve: () => void;
  onCopy: () => void;
  onOpenSource: () => void;
}) {
  return (
    <div className={styles.stageContent}>
      <div className={styles.taskContext}>
        <div className={styles.taskHeader}>
          <span className={styles.taskIcon}>
            <MessageSquareText aria-hidden="true" size={19} strokeWidth={1.7} />
          </span>
          <div>
            <p>当前任务</p>
            <h2>继续讨论 DayPage 的商业模式</h2>
          </div>
        </div>
        <div className={styles.userQuestion}>
          “我们该先做免费层，还是直接测试年付？”
        </div>

        {!contextReady ? (
          <div className={styles.retrievalPrompt}>
            <Search aria-hidden="true" size={23} strokeWidth={1.6} />
            <div>
              <h3>调用与当前问题相关的已确认记忆</h3>
              <p>候选、被忽略内容和未确认人格推断不会进入结果。</p>
            </div>
            <button
              type="button"
              className={styles.primaryButton}
              disabled={isRetrieving || !isConfirmed}
              onClick={onRetrieve}
            >
              {isRetrieving ? (
                <>
                  <LoaderCircle
                    className={styles.spinner}
                    aria-hidden="true"
                    size={17}
                    strokeWidth={1.9}
                  />
                  正在检索
                </>
              ) : (
                <>
                  调用记忆
                  <ArrowRight aria-hidden="true" size={17} strokeWidth={1.8} />
                </>
              )}
            </button>
          </div>
        ) : (
          <div className={styles.contextPacket}>
            <div className={styles.contextPacketHeader}>
              <div>
                <CheckCircle2 aria-hidden="true" size={17} strokeWidth={2} />
                <strong>找到一条已确认决定</strong>
              </div>
              <span>相关度高</span>
            </div>
            <h3>{title}</h3>
            <p>{reason}</p>
            <div className={styles.contextEvidence}>
              <div>
                <Quote aria-hidden="true" size={15} strokeWidth={1.7} />
                <span>
                  “定价先不要做免费层。早期应该用年付去验证。”
                </span>
              </div>
              <button type="button" onClick={onOpenSource}>
                今天 09:18 语音
                <Link2 aria-hidden="true" size={13} strokeWidth={1.8} />
              </button>
            </div>
            <div className={styles.contextCounter}>
              <strong>同时带回反证</strong>
              用户把来源透明和完整导出视为付费前提。
            </div>
            <button
              type="button"
              className={styles.primaryButton}
              disabled={copied}
              onClick={onCopy}
            >
              {copied ? (
                <>
                  <Check aria-hidden="true" size={16} strokeWidth={2} />
                  已记录复用
                </>
              ) : (
                <>
                  <Clipboard aria-hidden="true" size={16} strokeWidth={1.8} />
                  复制上下文并继续
                </>
              )}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

function WeeklyStage({
  title,
  sourceCount,
  resolution,
  onResolve,
  onRestart,
  onOpenSource,
  sources,
}: {
  title: string;
  sourceCount: number;
  resolution: "kept" | "review" | null;
  onResolve: (value: "kept" | "review") => void;
  onRestart: () => void;
  onOpenSource: (source: Source) => void;
  sources: Source[];
}) {
  const unclassifiedSources = sources.slice(3);

  return (
    <div className={styles.stageContent}>
      <div className={styles.weeklyGrid}>
        <section className={styles.weekSignal}>
          <div className={styles.weekSignalHeader}>
            <CalendarRange aria-hidden="true" size={19} strokeWidth={1.7} />
            <span>本周真正变化的内容</span>
          </div>
          <strong className={styles.bigNumber}>2</strong>
          <p>次关于定价的判断变化</p>
          <dl>
            <div>
              <dt>已确认决定</dt>
              <dd>1</dd>
            </div>
            <div>
              <dt>原始证据</dt>
              <dd>{sourceCount}</dd>
            </div>
            <div>
              <dt>上下文复用</dt>
              <dd>1</dd>
            </div>
          </dl>
        </section>

        <article className={styles.weekReview}>
          <div className={styles.weekReviewHeader}>
            <div>
              <p>需要你判断</p>
              <h2>{title}</h2>
            </div>
            <span>周五回顾</span>
          </div>

          <div className={styles.balance}>
            <section>
              <strong>支持</strong>
              <p>两条记录认为直接收费能更快验证不可替代性。</p>
              <button type="button" onClick={() => onOpenSource(sources[0])}>
                查看证据
              </button>
            </section>
            <section>
              <strong>反证</strong>
              <p>一次访谈指出，付费依赖来源透明和完整导出。</p>
              <button type="button" onClick={() => onOpenSource(sources[2])}>
                查看证据
              </button>
            </section>
          </div>

          {unclassifiedSources.length > 0 && (
            <div className={styles.unclassifiedReceipt}>
              <FileText aria-hidden="true" size={17} strokeWidth={1.8} />
              <p>
                <strong>{unclassifiedSources.length} 条原始证据未被自动归因</strong>
                它仍然保留，但没有参与当前决定，等待你确认它属于支持、反证或另一条思路。
              </p>
              <button
                type="button"
                onClick={() => onOpenSource(unclassifiedSources[0])}
              >
                查看
              </button>
            </div>
          )}

          <div className={styles.weekQuestion}>
            <CircleHelp aria-hidden="true" size={20} strokeWidth={1.7} />
            <div>
              <strong>这条反证是否足以改变本周的决定？</strong>
              <p>DayPage 不替你完成最后一步判断。</p>
            </div>
          </div>

          {resolution ? (
            <div className={styles.finalReceipt}>
              <CheckCircle2 aria-hidden="true" size={22} strokeWidth={2} />
              <div>
                <strong>
                  {resolution === "kept" ? "决定保持不变" : "已标记下周复查"}
                </strong>
                <p>闭环完成：本周记录了一次有证据的上下文复用。</p>
              </div>
              <button
                type="button"
                className={styles.secondaryButton}
                onClick={onRestart}
              >
                重新体验
              </button>
            </div>
          ) : (
            <div className={styles.resolutionActions}>
              <button
                type="button"
                className={styles.secondaryButton}
                onClick={() => onResolve("review")}
              >
                <Clock3 aria-hidden="true" size={16} strokeWidth={1.8} />
                下周复查
              </button>
              <button
                type="button"
                className={styles.primaryButton}
                onClick={() => onResolve("kept")}
              >
                <Check aria-hidden="true" size={16} strokeWidth={2} />
                保持决定
              </button>
            </div>
          )}
        </article>
      </div>
    </div>
  );
}
