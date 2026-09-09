# 8. Git workflow

How to save your changes and push them to GitHub. This repo's remote is
`git@github.com:fhlkfds/arch-autodepoly.git`, on branch `main`.

---

## The one rule

**Never commit an unencrypted `group_vars/all/vault.yml`.**

It holds your password hash and SSH public key. `.gitignore` already excludes it, but check
anyway before every push:

```bash
git status --short | grep vault        # should print NOTHING
head -1 group_vars/all/vault.yml       # should print $ANSIBLE_VAULT;1.1;AES256
```

If the first command prints anything, stop and read
[if you committed the vault by mistake](#if-you-committed-the-vault-by-mistake).

## What git ignores

From `.gitignore`:

```
artifacts/                 # prove-idempotency.sh transcripts
group_vars/all/vault.yml   # your secrets
*.retry
```

Everything else is tracked, including `docs/`.

---

## One-time setup

If git does not know who you are yet:

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

Check that pushing works (SSH remote, so you need a key on GitHub):

```bash
ssh -T git@github.com          # "Hi <user>! You've successfully authenticated"
```

If that fails, add your public key at <https://github.com/settings/keys>.

---

## The normal loop

```bash
# 1. What changed?
git status
git diff                      # unstaged changes, line by line

# 2. Sanity-check before saving
ansible-playbook --syntax-check site.yml
yamllint .
for t in tests/*.test.sh; do bash "$t"; done

# 3. Stage
git add group_vars/all/main.yml roles/packages/tasks/main.yml
#    or everything:  git add -A

# 4. Review exactly what you are about to commit
git diff --staged

# 5. Commit
git commit -m "fix: copy wallhaven-dl from the controller checkout"

# 6. Push
git push
```

### Commit message style

The repo's history uses [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: expand workstation provisioning
fix:  provision desktop integrations
```

Prefixes: `feat:` new capability, `fix:` corrects broken behaviour, `docs:` documentation
only, `refactor:` no behaviour change, `chore:` tooling and housekeeping. Keep the subject
under ~72 characters, imperative mood ("add", not "added").

For anything non-obvious, add a body explaining **why**, not what — the diff already shows
what:

```bash
git commit -m "fix: copy wallhaven-dl from the controller checkout" -m \
"fhlkfds/wallhaven-tools is private, so the target cannot clone it: there are
no GitHub credentials there and ssh_allow_agent_forwarding is false. Copy the
script from the controller's checkout instead."
```

---

## Working on a branch

Safer for anything larger than a one-line fix, and required if you want review.

```bash
git checkout -b fix/wallhaven-source     # branch off main
# ... edit, test ...
git add -A
git commit -m "fix: copy wallhaven-dl from the controller checkout"
git push -u origin fix/wallhaven-source  # -u sets the upstream, once per branch
```

Then open a pull request. With the GitHub CLI:

```bash
gh pr create --fill                      # uses your commit message
gh pr view --web
```

Or click the link GitHub prints after the push.

Merging it:

```bash
gh pr merge --squash --delete-branch
git checkout main
git pull
```

---

## Staying in sync

```bash
git pull                       # fetch + merge origin/main
git pull --rebase              # same, but replays your commits on top — cleaner history
```

If you edited a file that also changed upstream, git stops with a conflict. Open the file,
look for `<<<<<<<` markers, pick the right content, then:

```bash
git add <file>
git rebase --continue          # if you used --rebase
# or: git commit               # if you used a plain pull
```

To abandon a messy rebase: `git rebase --abort`.

---

## Undoing things

```bash
git restore <file>                  # discard unstaged edits to one file
git restore --staged <file>         # unstage, keep the edits
git commit --amend                  # fix the LAST commit (only if not pushed)
git revert <sha>                    # new commit undoing an old one — safe after pushing
git reset --hard origin/main        # NUCLEAR: throw away all local work
```

`git log --oneline -10` to find a sha. Avoid `reset --hard` unless you are sure.

---

## Before you push, checklist

- [ ] `git status --short | grep vault` prints nothing
- [ ] `ansible-playbook --syntax-check site.yml` passes
- [ ] `yamllint .` is clean (one `document-start` warning on the encrypted vault is normal)
- [ ] `for t in tests/*.test.sh; do bash "$t"; done` — all `ok:`
- [ ] `git diff --staged` shows only what you meant to change
- [ ] No real IP addresses or hostnames you did not intend to publish (`admin_ips` and
      `localsend_source_ranges` are **tracked**, so whatever is in them goes to GitHub —
      override them from `vault.yml` if that matters to you)

---

## If you committed the vault by mistake

Assume the contents are compromised the moment they are pushed.

```bash
# 1. Stop tracking it, keep the local file
git rm --cached group_vars/all/vault.yml
echo 'group_vars/all/vault.yml' >> .gitignore     # already there, but confirm
git commit -m "chore: stop tracking the vault file"
git push
```

That removes it from *future* commits but **not from history**. If it was ever pushed:

1. Change the account password on the target and regenerate the hash with
   `scripts/make-password-hash.py`.
2. Rotate the SSH key pair: generate a new one, `ssh-copy-id` it, remove the old public key
   from `~/.ssh/authorized_keys`.
3. Change the vault password itself:
   `ansible-vault rekey group_vars/all/vault.yml`.
4. Optionally scrub history with `git filter-repo` — but rotation is what actually protects
   you, and it is what you should do first.

An *encrypted* vault in history is far less serious, but the same rekey advice applies.

---

## Where to go next

Back to the [wiki index](README.md), or the
[manual procedure](../LOCAL-SOP.md) if you want to run this without Ansible.
