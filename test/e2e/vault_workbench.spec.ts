import { expect, test } from "./support/fixtures";

test("owner unlocks and renders the empty Vault Workbench", async ({
  page,
  loginAsOwner,
  unlockVault,
}) => {
  await loginAsOwner();

  await expect(page).toHaveURL("/vault/unlock");
  await expect(page.getByRole("heading", { name: "Unlock vault", level: 1 })).toBeVisible();

  await unlockVault();

  await expect(page).toHaveURL("/assets");
  await expect(page.getByRole("heading", { name: "Vault assets", level: 1 })).toBeVisible();
  await expect(
    page.getByText("No assets match the current catalogue filters.", { exact: true }),
  ).toBeVisible();
});
