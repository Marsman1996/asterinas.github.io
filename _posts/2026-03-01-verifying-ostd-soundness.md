---
layout: post
title: "Proving Soundness for Unsafe Rust: Lessons from a Kernel"
date: 2026-03-30 09:00:00 +0800
author: [Asterinas Team, CertiK]
categories: [formal-verification, rust, kernel]
tags: [unsafe, soundness, verus, ostd, asterinas]
updated: 2026-03-30 11:35:44
---

*(Foreword: This post summarizes our progress in verifying OSTD and highlights key results from our research papers. This work is carried out in collaboration with [CertiK](https://www.certik.com/).)*

Kernel programming inherently requires `unsafe` code because hardware doesn't understand Rust's safe abstractions. At the lowest levels, CPUs process raw physical addresses, and hardware writes directly to memory, forcing the code to cross the language boundary.

The mental model of Rust developers to manage `unsafe` code relies on the **"Tootsie Pop" model**:

- **The Core:** A small, meticulously audited `unsafe` center.
- **The Shell:** Safe public interfaces wrapping the core, backed by manual '`// SAFETY: ...`' comments where developers promise the code won't trigger undefined behavior.

<img src="/assets/images/tootsie_pop.png" alt="The Tootsie Pop model" style="width: 80%;" />

This approach allows the vast majority of a codebase to remain perfectly safe. However, it has a fundamental limit: Rust's safety guarantees only apply within its own formal *abstract machine*. It is entirely possible to corrupt memory from the outside, such as using the OS to write directly to a variable's address (e.g., via `/proc/self/mem` [^1]), without ever breaking Rust's internal rules.

While a standard library developer can safely treat these external hardware and OS interventions as out-of-scope edge cases, a kernel developer does not have that luxury.

[^1]: If you are curious to see exactly how this loophole is exploited, you can dive into the [`totally_safe_transmute`](https://blog.yossarian.net/2021/03/16/totally_safe_transmute-line-by-line) crate for a fascinating, step-by-step demonstration.

Because a kernel doesn't just run inside the abstract machine, it *implements* it. The kernel is responsible for creating the very environment Rust takes for granted by:

- Allocating the physical memory pages Rust relies on.
- Installing the page tables to validate virtual addresses.
- Configuring the hardware (like the IOMMU) that restricts memory access.

If the kernel's trusted core is unsound, the entire abstract machine collapses. This brings us to a critical question: how do you prove the "Tootsie Pop" shell holds when you are responsible for building its very foundation?

For a kernel, facing adversarial OS code, unpredictable user programs, and direct hardware interference, human promises fall short. We need more than comments; but rather **machine-checked proofs** ensuring the boundary holds against any caller, in any order, from any direction.

## Asterinas and the High Stakes of Kernel Security

**[Asterinas](https://github.com/asterinas/asterinas)** is a Linux ABI-compatible OS kernel written entirely in Rust. While it matches Linux in performance and supports over 210 system calls, its true innovation lies in its structure. Asterinas utilizes a **[framekernel architecture](https://asterinas.github.io/book/kernel/the-framekernel-architecture.html)** that enforces a strict separation between *mechanism* and *policy*:

- **The Mechanisms:** The Operating System Standard Library ([OSTD](https://asterinas.github.io/book/ostd/index.html)) is the foundation. It handles the raw, dangerous primitives: physical memory management, page tables, and hardware configuration. These are the operations that can corrupt the abstract machine if misused.
- **The Policies:** Everything built on top of OSTD, such as scheduling, file systems, and network protocols, dictates system behavior. This layer is implemented entirely in *safe Rust*, strictly enforced by `#![deny(unsafe_code)]` in every crate outside OSTD.

This boundary is not arbitrary; it perfectly divides the code that *can* corrupt the system's foundation from the code that *cannot*.

### The Weight of the Foundation

Because of this architecture, OSTD's soundness is incredibly load-bearing. OSTD consists of about 15,000 lines of mechanism code. Sitting above it are over 100,000 lines of safe policy code. This massive upper layer automatically inherits memory safety *if and only if* OSTD's public API is sound. A bug in OSTD isn't just a localized issue; it is a crack in the foundation that every other crate relies on.

Proving OSTD sound is far more complex than verifying a standard library because its adversary model is much broader. OSTD must hold its ground simultaneously against three distinct threats:

1. **Safe OS service code:** Arbitrary callers operating normally within the abstract machine.
2. **User programs:** External applications interacting (and potentially probing for weaknesses) through virtual memory interfaces.
3. **Peripheral devices:** Hardware operating completely outside the abstract machine via DMA.

Defending against all three requires [extending the Rust soundness definition](https://asterinas.github.io/book/ostd/soundness/what-soundness-means.html) to guarantee zero undefined behavior (UB) at the language, environment, or architecture level, against any adversary.

### Defining the Formal Guarantee

The simplest way to express the guarantee that OSTD can withstand these threats is to use a Hoare triple:

$$
\{P_{\text{safe}}\} C \{Q_{\text{sound}}\}
$$

Here is what that means in plain English:

- **$P_{\text{safe}}$ (The Precondition):** The calling program is written in safe Rust. The Rust compiler checks and enforces this automatically, at no cost to the developer.
- **$C$ (The Code):** Any program built using OSTD's API calls.
- **$Q_{\text{sound}}$ (The Postcondition):** No undefined behavior is triggered anywhere in kernel space.

**When you connect these three pieces, the formula makes a massive claim:** **If** a developer only uses standard, safe Rust ($P_{\text{safe}}$), **then regardless of what** sequence of OSTD functions they decide to execute ($C$), the kernel is guaranteed to **never** suffer from undefined behavior ($Q_{\text{sound}}$).

The sheer difficulty of this proof lies in `C`. The guarantee must hold universally for *any* arbitrary caller, even code that the OSTD developers have never seen or anticipated.

## The Road to OSTD Soundness

Let’s dive into the central proof obligation in a more formal way:

$$
\forall \mathcal{C}. \; (\vdash \mathcal{C} : \text{SafeRust}) \implies \mathcal{C}[\text{OSTD}] \models Q_{\text{sound}}
$$

It reads for all contexts ($\mathcal{C}$), when it runs on OSTD’s implementation ($\mathcal{C}[OSTD]$), combined with what the Rust type system enforces ($\vdash \mathcal{C} : \text{SafeRust}$), must guarantee soundness. Achieving this requires solving three fundamental problems:

**Challenge #1: Extending the Abstract Machine to Capture Every Threat**

Rust models memory purely as safely typed allocations, which is completely blind to kernel-level realities. Concepts like raw physical frames, hardware-controlled page tables, and DMA buffers simply do not exist in standard Rust. If the verifier’s formal model (the abstract machine) doesn’t understand these hardware elements, it cannot prove the system is safe from them. The model must be extended first.

**Challenge #2: Composing Proofs Across Deep Abstraction Layers**

A kernel subsystem like memory management is a deeply layered stack, spanning from raw hardware allocation up to complex virtual memory mapping. A public API is only as sound as the internal functions it calls. Therefore, mathematical proofs must compose perfectly from the bottom up, meaning the strictly verified correctness of low-level internal code is an absolute prerequisite for the top-level API's soundness.

**Challenge #3: Defending Against an Infinite Number of Callers**

The kernel must be proven safe for *any* safe code that might eventually be linked against it. Verifying internal functions in perfect isolation isn't enough, as an outside caller might execute them in an unexpected sequence that breaks the system's state. We must translate an impossible, infinite obligation ("safe against all possible callers") into a finite mathematical property that a machine verifier can actually check.

A year ago, [our Phase I groundwork](https://asterinas.github.io/2025/02/13/towards-practical-formal-verification-for-a-general-purpose-os-in-rust.html) successfully verified isolated functions within the memory management (`mm`) module. While meaningful, these proofs were localized. They worked around the abstract machine function-by-function and still could not guarantee safety against unknown external callers.

**This post marks Phase II.** The leap forward is not just that we verified *more* functions, but that we successfully proved our universal formula. The public API of the entire `mm` module is now formally proven sound against any safe caller, executing in any order.

### Building the Proof: Extending the Model with "Ghost State"

Because our three challenges are deeply connected, they must be solved in sequence. To extend our model to understand hardware, we use **[Verus](https://github.com/verus-lang/verus)**, a deductive verification tool designed specifically for Rust. Verus allows us to write mathematical specifications directly alongside our normal Rust code.

Its most powerful feature for kernel development is **ghost state**: special types that exist *only* during the verification process. They are completely erased before the code runs, meaning they carry zero performance overhead. We use `ghost` state to formally model the hardware concepts that standard Rust doesn't understand:

- **`PointsTo<T>`:** Proves valid ownership of raw memory before a pointer can be dereferenced.
- **`EntryOwner<C>`:** Represents exclusive ownership of a hardware page table entry.
- **`MetaRegionOwners`:** Tracks the global state of the physical frame metadata.
- **`CursorModel`:** Translates raw page table pointers into an abstract, verifiable mathematical sequence.

To make this concrete, consider `CursorModel`. The page table cursor is implemented as a pointer traversing a tree of page-table structures, with a messy, hardware-dependent runtime representation that includes reference-count bookkeeping. Writing proofs directly against it is nearly impossible. Instead, we use a `ghost` type called `CursorModel` to strip away the hardware noise, reducing it to a single logical question: *where is the cursor in the sequential address space?*

```rust
// Ghost type — exists only during verification, zero runtime cost
pub ghost struct CursorModel {
    pub ghost fore: Seq<LinkModel>,  // elements before the cursor
    pub ghost rear: Seq<LinkModel>,  // elements after the cursor
    pub ghost list_model: LinkedListModel,
}
```

Behind the scenes, we write a `ghost` function that relates the physical cursor index to these two abstract sequences (`fore` and `rear`). This refinement helps to establish strict formal rules, such as the **partition invariant**:

```rust
// The PT entries before and after the cursor must perfectly 
// combine to form the entire page table, 
// with no elements lost or duplicated.
fore + rear == list_model.list
```

With `CursorModel`, this partition is machine-checked at compilation. If buggy code silently drops an element, duplicates an entry, or leaves a dangling pointer, the verification breaks. The verifier catches the proof failure immediately, long before it can become a catastrophic memory bug in the running kernel.

By introducing `ghost` states and refinement proof, comments like `// SAFETY: we exclusively own this physical frame` transform into rules that Verus actively checks at compilation.

### Taming the Undefined Behavior: Proving Soundness

In formal logic, proving the *absence* of something across an open system is mathematically intractable.

To prove that Undefined Behavior (UB) *never* happens when the kernel is linked against an unknown caller, you would have to anticipate every possible input and call sequence. Because the space of potential interactions is infinite, proving this negative is impossible. You cannot search an infinite space to prove it is empty.

This brings us to a foundational principle in formal methods, attributed to Andrew Appel:

> The best way to show that a program has no undefined behavior is to show that it has a particular defined behavior.

Instead of trying to prove a negative, we prove a strict positive. By using mathematical contracts (`requires` and `ensures` clauses), we lock down exactly what a function *does* for every valid input. When you mathematically prove that a program's behavior is 100% defined, there is simply no room left in the state space for undefined behavior to exist.

This positive approach also yields an incredibly powerful by-product: **functional correctness** at the OSTD API level. Because we are forced to explicitly define what every function *does* to rule out undefined behavior, every public API naturally acquires a clear, formally verified specification. Ultimately, we don't just guarantee that the kernel won't have UB, but guarantee exactly how it will behave.

### Vertical Composition: Building Soundness from the Ground Up

With our extended model, we can write precise specifications. However, the memory management (`mm`) module is a deeply layered stack: spanning from raw physical frames at the bottom to high-level virtual memory interfaces at the top. A public soundness guarantee cannot exist in a vacuum; it must be built bottom-up.

> Correctness at the Bottom is Soundness at the Top

When Verus verifies a function, it relies strictly on the *specifications* of the functions it calls, not their underlying code. This means the top layer's proof is only as strong as the layer beneath it.

Consider this chain from the `page_table` module:

<img src="/assets/images/correctness_bottom_up.png" alt="Correctness at the Bottom is Soundness at the Top" style="width: 65%;" />

To prove the public `map` function is safe, the verifier needs an exact mathematical guarantee of what the hardware-level `replace` function does. The key insight:

> Correctness and soundness are not parallel goals. Strictly proving functional correctness at the lowest internal levels is the structural mechanism that guarantees soundness at the top.

<img src="/assets/images/soundness_correctness.png" alt="Soundness and Correctness" style="width: 65%;" />

#### What a Good Spec Looks Like

This vertical dependency requires two distinct types of specifications across the codebase:

- **Internal Specs (for the verifier):** These must be exhaustively precise. They capture exactly what a function modifies and what it leaves unchanged, providing the rigid mathematical foundation that higher-layer proofs depend on.
- **Public API Specs (for humans):** These must be clear and abstract. Instead of mirroring messy implementation details, which risks accidentally validating bugs, they focus purely on logical intent. `CursorModel` is a perfect example: internally, it relies on complex pointer arithmetic, but its public specification simply presents a clean, mathematically partitioned sequence (`fore` and `rear`).

With vertical composition, per-function proofs successfully chain from the bottom of the stack to the top. We can prove a function is sound *if* its preconditions are met upon entry. The final hurdle is figuring out how to enforce those preconditions when an unknown caller executes these APIs in an unpredictable sequence.

### Horizontal Composition: Defending Against Infinite Callers

Vertical composition proves that a function works perfectly *if* its preconditions are met. But an unpredictable safe caller can invoke APIs in any order, storing and reusing handles however they like. Who guarantees the kernel's state remains valid across the gap between one API call and the next?

The answer is the kernel itself, using **system invariants**.

#### Solving the Infinite Execution Context Problem

The key to solving this challenge is realizing that safe Rust cannot forge or duplicate resources. A caller cannot magically manufacture a memory `Frame` out of thin air, nor can they clone one. Their power is strictly limited to exactly what the kernel's API hands them.

This elegantly bounds the problem. Instead of trying to anticipate an infinite number of possible caller sequences, we simply reason about the *state* of the kernel. We define a strict set of global rules (**system invariants**) and follow a three-step mathematical strategy:

1. **Define the rules:** Identify the state invariants required to guarantee defined behavior.
2. **Prove the start:** Prove these rules hold true when the system initializes.
3. **Prove the transitions:** Prove that every single public API function *preserves* these rules, assuming they hold when the function is called, they must still hold when it returns.

By mathematical induction, if the system starts in a valid state, and every possible API call preserves that valid state, then undefined behavior simply cannot be reached.

#### The `relate_region` Invariant in Action

To see this in practice, look at `relate_region`, the most critical system invariant in the memory management (`mm`) module. This rule forces the page table entries (`EntryOwner`) to perfectly match the global physical memory records (`MetaRegionOwners`).

```rust
impl<C: PageTableConfig> EntryOwner<C> {
    pub open spec fn relate_region(self, regions: MetaRegionOwners) -> bool {
        if self.is_node() {
            let idx = frame_to_index(self.meta_slot_paddr.unwrap());
            let slot_owner = regions.slot_owners[idx];
            &&& slot_owner.inner_perms.refcount.value() != REFCOUNT_UNUSED
            &&& slot_owner.raw_count == self.expected_raw_count
            &&& slot_owner.self_addr == self.node.unwrap().meta_perm.addr
            &&& self.node.unwrap().meta_perm.points_to.value().wf(slot_owner)
            &&& slot_owner.path_if_in_pt is Some
            &&& slot_owner.path_if_in_pt.unwrap() == self.path
        } else if self.is_frame() { ... } else { true }
    }
}
```

This `spec` code asserts something highly concrete for every single entry in the page table: the reference counts are valid, the pointers agree, and the path through the page table matches the global metadata exactly.

**What does this prevent?** **Ownership inconsistency: an `EntryOwner` that has lost track of where its entry actually sits in the page table tree.**

If an entry is moved from path A to path B without updating the metadata, `EntryOwner` and `MetaRegionOwners` hold contradictory beliefs about the same physical entry. `relate_region` breaks immediately. Left uncaught, this inconsistency is the root of silent failure: a cleanup operation following the stale path A frees a frame that path B still points to; reference counts drift out of sync; a later insertion sees a slot as empty when it is not. Preserving `relate_region` at every API call site is the machine-checked proof that these contradictions can never arise.

## Does the Methodology Scale?

A verification approach is only practical if it can be executed without a massive, multi-year engineering effort. Here is the evidence that our methodology not only works in theory but actually scales in practice.

### Total Verification of the `mm` Module

We have formally verified the entire memory management (`mm`) module: from raw physical frame allocation at the bottom to virtual address space mapping at the top. This isn't just a collection of isolated checks; we successfully proved the soundness guarantee against all adversary classes. Additionally, in a parallel effort of CortenMM, the OSTD has been verified for the complex concurrent correctness of the page table's fine-grained locking.

### Slashing the Proof Cost to a 1:4 Ratio

Historically, formal verification requires about 20 lines of mathematical proof for every 1 line of code (a 1:20 ratio). This immense cost has blocked widespread industrial adoption. **We reduced this ratio to below 1:4.** This efficiency comes from two factors: Verus’s automated SMT solver effortlessly handles routine mathematical obligations in the background, and OSTD’s tightly scoped, modular architecture prevents proof complexity from spiraling out of control.

### AI-Assisted Verification

Because proof annotations often follow predictable patterns, we built **KVerus**, an AI-assisted tool that automatically generates a growing fraction of our proofs. Crucially, AI assistance accelerates the writing process but does not alter the trustworthiness of the results. Every single proof generated by KVerus is strictly checked and validated by Verus's mathematical solver.

### Living Infrastructure, Not Static Snapshots

The biggest critique of formal verification is that proofs quickly become outdated as code evolves. We began our verification on OSTD v0.15 and are currently tracking v0.16.2. Thanks to our modular invariant structure and KVerus's ability to help repair proofs, updating our verification alongside codebase changes has proven highly manageable. Our ultimate goal is continuous verification: updating proofs in the exact same pull request as the code they cover.

### Clear Trusted Foundations

Every formal proof must rest on foundational axioms. For OSTD, we assume that the underlying hardware mechanisms function correctly. We also operate within Rust's current provisional aliasing rules. Clearly defining exactly where our proofs end and our trusted hardware assumptions begin is a core feature of a secure, well-designed system.

## From Promise to Proof

Let's now review the fundamental question: how do you prove that a safe abstraction holds when you are the one building its very foundation? The answer lies in fundamentally shifting how we reason about the kernel:

- **Formalize the unseen:** You cannot prove what you cannot describe. By formally modelling raw, physical realities, we bridge the gap between the physical machine and the logic that governs it.
- **Assert the positive:** Rather than endlessly chasing the infinite ways a system might fail, we explicitly define exactly what it *must* do. Certainty comes from constructing truth, not merely avoiding error.
- **Anchor the foundation:** High-level promises are only as strong as their lowest-level implementations. Correctness at the deepest, most hidden layers is the structural prerequisite for trust at the surface.
- **Bound the infinite:**  Rather than trying to anticipate every possible interaction, we establish systemic laws (invariants) that constrain chaos and make the infinite logically finite.

Returning to our earlier `totally_safe_transmute` example, we know that Rust's safety guarantees end at the boundary of its abstract machine. A formally verified OSTD proves that an operating system can take full responsibility for defending that boundary.

More importantly, this underlying problem is not unique to kernels. Any Rust project relying on a complex `unsafe` core faces the exact same challenges.

While our specific ghost types (`PointsTo`, `EntryOwner`) are unique to kernels, the verification strategy itself is universal. We chose to pioneer this methodology in the kernel and find that it works.
