# Plan de Corrección: Snapshot Workflow

## Root Cause
El workflow intenta pushear a `refs/pull/{number}/head` que es read-only.
El push falla silenciosamente, dejando el commit solo en el runner.
El siguiente job intenta checkout de un SHA que no existe en GitHub.

## Solución

### Cambio en `code-npm_node-publish_snapshot.yml`

**Obtener la branch real del PR:**

```yaml
- name: Get PR branch name
  id: get-pr-info
  uses: actions/github-script@v7
  with:
    script: |
      const { data: pr } = await github.rest.pulls.get({
        owner: context.repo.owner,
        repo: context.repo.repo,
        pull_number: context.issue.number
      });
      core.setOutput('head_ref', pr.head.ref);
      core.setOutput('pr_ref', `refs/pull/${context.issue.number}/head`);
```

**Actualizar outputs del job:**

```yaml
outputs:
  snapshot_version: ${{ steps.define-version.outputs.snapshot_version }}
  head_ref: ${{ steps.get-pr-info.outputs.head_ref }}  # Branch real
  pr_ref: ${{ steps.get-pr-info.outputs.pr_ref }}      # Para checkout
```

**Pasar branch al reusable:**

```yaml
publish-snapshot:
  with:
    checkout-ref: ${{ needs.prepare-and-publish-snapshot.outputs.pr_ref }}
    push-ref: ${{ needs.prepare-and-publish-snapshot.outputs.head_ref }}  # Branch, no PR ref
```

### Mejora en `code-npm_node-publish-reusable.yml`

**Hacer el push visible (no silencioso):**

```yaml
- name: Push changes
  if: inputs.push-ref != ''
  run: |
    git push origin HEAD:${{ inputs.push-ref }}
```

Remover el `|| echo` para que el error sea visible si falla.

## Verificación

1. El prepare job hará checkout del PR ref (read-only, está bien)
2. Hará commit local
3. Pusheará a la branch real del PR (read-write)
4. El publish job podrá hacer checkout del SHA que ahora existe en GitHub

## Testing

Probar con `/publish-snapshot` en un PR real.
