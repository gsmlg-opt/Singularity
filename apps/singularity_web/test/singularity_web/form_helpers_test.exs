defmodule SingularityWeb.FormHelpersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import SingularityWeb.FormHelpers

  test "the default locale is English" do
    assert Gettext.get_locale(SingularityWeb.Gettext) == "en"
  end

  test "translate_error/1 goes through the errors domain with interpolation and plurals" do
    assert translate_error({"can't be blank", [validation: :required]}) == "can't be blank"

    assert translate_error(
             {"should be at most %{count} character(s)",
              [count: 100, validation: :length, kind: :max, type: :string]}
           ) == "should be at most 100 character(s)"
  end

  test "field_errors/1 shows a field's errors only after validation" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required(:name)

    fresh = Phoenix.Component.to_form(changeset, as: :thing)
    refute render_component(&field_errors/1, form: fresh, field: :name) =~ "blank"

    validated = Phoenix.Component.to_form(%{changeset | action: :validate}, as: :thing)

    assert render_component(&field_errors/1, form: validated, field: :name) =~
             "can&#39;t be blank"
  end
end
