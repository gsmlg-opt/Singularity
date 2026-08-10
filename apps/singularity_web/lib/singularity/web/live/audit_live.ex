defmodule Singularity.Web.AuditLive do
  use Singularity.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Phoenix.Component.assign(socket, page_title: "Audit")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Audit">
      <section aria-labelledby="restore-integrity-heading">
        <h2 id="restore-integrity-heading">Restore integrity acceptance</h2>
        <p>
          Integrity verification is a restore operation. The command
          <code>mix singularity.test.restore</code>
          is the only integrity acceptance proof.
        </p>
        <p>This page does not perform an integrity audit against the live vault.</p>
      </section>
    </.page>
    """
  end
end
