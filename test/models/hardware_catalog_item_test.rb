# frozen_string_literal: true

require "test_helper"

class HardwareCatalogItemTest < ActiveSupport::TestCase
  test "lookup_identifier resolves exact UPC" do
    item = HardwareCatalogItem.create!(
      canonical_purl: "pkg:generic/test/device1",
      vendor: "TestVendor",
      model: "model-1",
      category_code: "C3",
      upc_gtin: "012345678905"
    )

    found = HardwareCatalogItem.lookup_identifier("012345678905")
    assert_equal item.id, found.id
  end

  test "lookup_identifier resolves FCC ID" do
    item = HardwareCatalogItem.create!(
      canonical_purl: "pkg:generic/test/device2",
      vendor: "TestVendor",
      model: "model-2",
      category_code: "C3",
      fcc_id: "SWX-UDMPRO"
    )

    found = HardwareCatalogItem.lookup_identifier("swx-udmpro")
    assert_equal item.id, found.id
  end

  test "lookup_identifier resolves Model name case-insensitively" do
    item = HardwareCatalogItem.create!(
      canonical_purl: "pkg:generic/test/device3",
      vendor: "Ubiquiti",
      model: "UDM-Pro",
      category_code: "C3"
    )

    found = HardwareCatalogItem.lookup_identifier("udm-pro")
    assert_equal item.id, found.id
  end
end
