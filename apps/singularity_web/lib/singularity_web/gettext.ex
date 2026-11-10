defmodule SingularityWeb.Gettext do
  @moduledoc """
  Gettext backend for the web UI. Messages live in `priv/gettext`, one domain
  per area (default, errors, overview, knowledge, source, system); msgids are
  English and English is the default locale. Adding a language only needs a new
  `.po` directory.
  """
  use Gettext.Backend, otp_app: :singularity_web
end
