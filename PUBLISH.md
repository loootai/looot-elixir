# Publishing looot to Hex

The Hex package is `looot` (it was free on hex.pm on 2026-11-06). Nothing is published yet.
Hex has no OIDC trusted publishing, so the release workflow uses an API key stored as a GitHub
secret. ExDoc documentation goes to https://hexdocs.pm/looot automatically with the package.

## One time, for Walid

1. Create a hex.pm account at https://hex.pm/signup, or run `mix hex.user register`. Use a
   looot owned email and confirm it.
2. On a machine with Elixir run `mix hex.user auth`, then
   `mix hex.user key generate --key-name looot-elixir-ci --permission api:write`. Copy the key
   it prints once. (Or on hex.pm: Dashboard, Keys, add a key with the API write permission.)
3. GitHub, loootai/looot-elixir, Settings, Environments, New environment `hex`. Limit it to
   tags `v*` and add yourself as a required reviewer. Add the environment secret `HEX_API_KEY`
   with the key from step 2.

## Every release

1. Set the same version in `mix.exs` (`@version`) and add a section to `CHANGELOG.md`.
2. Run `mix test`, `mix format --check-formatted`, `mix hex.build` and
   `bash scripts/leak-scan.sh .`.
3. Commit, then tag and push:

   ```sh
   git tag v0.1.0
   git push origin main v0.1.0
   ```

4. Approve the `hex` deployment in the Actions tab. The workflow checks that the tag matches
   `@version`, runs the tests, runs `mix hex.publish --yes` and creates the GitHub release.
5. Check https://hex.pm/packages/looot and https://hexdocs.pm/looot.

A Hex release can be reverted only within one hour of publishing (`mix hex.publish --revert
0.1.0`), and the version number is gone for good after that. Ship a new patch version instead.
