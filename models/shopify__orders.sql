with orders as (

    select 
        *,
        {{ dbt_utils.generate_surrogate_key(['source_relation', 'order_id']) }} as orders_unique_key
        , if(cancel_reason IS NULL,FALSE,TRUE) as is_canceled --EL Custom
    from {{ var('shopify_order') }}
 
), order_lines as (

    select *
    from {{ ref('shopify__orders__order_line_aggregates') }}

), order_adjustments as (

    select *
    from {{ var('shopify_order_adjustment') }}

), order_adjustments_aggregates as (
    select
        order_id,
        source_relation,
        sum(amount) as order_adjustment_amount,
        sum(tax_amount) as order_adjustment_tax_amount
    from order_adjustments
    group by 1,2

), refunds as (

    select *
    from {{ ref('shopify__orders__order_refunds') }}

), refund_aggregates as (
    select
        order_id,
        source_relation,
        sum(subtotal) as refund_subtotal,
        sum(total_tax) as refund_total_tax
    from refunds
    group by 1,2

), order_discount_code as (
    
    select *
    from {{ var('shopify_order_discount_code') }}

), discount_aggregates as (

    select 
        order_id,
        source_relation,
        sum(case when type = 'shipping' then amount else 0 end) as shipping_discount_amount,
        sum(case when type = 'percentage' then amount else 0 end) as percentage_calc_discount_amount,
        sum(case when type = 'fixed_amount' then amount else 0 end) as fixed_amount_discount_amount,
        count(distinct code) as count_discount_codes_applied

    from order_discount_code
    group by 1,2

), order_tag as (

    select
        order_id,
        source_relation,
        {{ fivetran_utils.string_agg("distinct cast(value as " ~ dbt.type_string() ~ ")", "', '") }} as order_tags
    
    from {{ var('shopify_order_tag') }}
    group by 1,2

), order_url_tag as (

    select
        order_id,
        source_relation,
        {{ fivetran_utils.string_agg("distinct cast(value as " ~ dbt.type_string() ~ ")", "', '") }} as order_url_tags
    
    from {{ var('shopify_order_url_tag') }}
    group by 1,2

), fulfillments as (

    select 
        order_id,
        source_relation,
        count(fulfillment_id) as number_of_fulfillments,
        {{ fivetran_utils.string_agg("distinct cast(service as " ~ dbt.type_string() ~ ")", "', '") }} as fulfillment_services,
        {{ fivetran_utils.string_agg("distinct cast(tracking_company as " ~ dbt.type_string() ~ ")", "', '") }} as tracking_companies,
        {{ fivetran_utils.string_agg("distinct cast(tracking_number as " ~ dbt.type_string() ~ ")", "', '") }} as tracking_numbers

    from {{ var('shopify_fulfillment') }}
    group by 1,2

), joined as (

    select
        orders.*,
        coalesce(cast({{ fivetran_utils.json_parse("total_shipping_price_set",["shop_money","amount"]) }} as {{ dbt.type_float() }}) ,0) as shipping_cost,
        
        order_adjustments_aggregates.order_adjustment_amount,
        order_adjustments_aggregates.order_adjustment_tax_amount,

        refund_aggregates.refund_subtotal,
        refund_aggregates.refund_total_tax,

        (orders.total_price
            + coalesce(order_adjustments_aggregates.order_adjustment_amount,0) + coalesce(order_adjustments_aggregates.order_adjustment_tax_amount,0) 
            - coalesce(refund_aggregates.refund_subtotal,0) - coalesce(refund_aggregates.refund_total_tax,0)) as order_adjusted_total,
        order_lines.line_item_count,

        coalesce(discount_aggregates.shipping_discount_amount, 0) as shipping_discount_amount,
        coalesce(discount_aggregates.percentage_calc_discount_amount, 0) as percentage_calc_discount_amount,
        coalesce(discount_aggregates.fixed_amount_discount_amount, 0) as fixed_amount_discount_amount,
        coalesce(discount_aggregates.count_discount_codes_applied, 0) as count_discount_codes_applied,
        coalesce(order_lines.order_total_shipping_tax, 0) as order_total_shipping_tax,
        order_tag.order_tags,
        order_url_tag.order_url_tags,
        fulfillments.number_of_fulfillments,
        fulfillments.fulfillment_services,
        fulfillments.tracking_companies,
        fulfillments.tracking_numbers,
        -- EL Custom.  Pulls shipping amount and amount with discount from existing columns in upstream models.  
        -- Instead of pulling the shipping discount from the discount_code (which misses some discounts), 
        -- it pulls the information from the shipping_lines. Use these insted of shipping_discount_amount. 
        coalesce(order_lines.order_total_shipping, 0) as order_total_shipping,
        coalesce(order_lines.order_total_shipping_with_discounts, 0) as order_total_shipping_with_discounts,
        coalesce(order_lines.order_total_shipping, 0) - coalesce(order_lines.order_total_shipping_with_discounts, 0) as order_total_shipping_discount


    from orders
    left join order_lines
        on orders.order_id = order_lines.order_id
        and orders.source_relation = order_lines.source_relation
    left join refund_aggregates
        on orders.order_id = refund_aggregates.order_id
        and orders.source_relation = refund_aggregates.source_relation
    left join order_adjustments_aggregates
        on orders.order_id = order_adjustments_aggregates.order_id
        and orders.source_relation = order_adjustments_aggregates.source_relation
    left join discount_aggregates
        on orders.order_id = discount_aggregates.order_id 
        and orders.source_relation = discount_aggregates.source_relation
    left join order_tag
        on orders.order_id = order_tag.order_id
        and orders.source_relation = order_tag.source_relation
    left join order_url_tag
        on orders.order_id = order_url_tag.order_id
        and orders.source_relation = order_url_tag.source_relation
    left join fulfillments
        on orders.order_id = fulfillments.order_id
        and orders.source_relation = fulfillments.source_relation

), windows as (

    select 
        *,
        row_number() over (
            partition by {{ shopify.shopify_partition_by_cols('customer_id', 'source_relation') }}
            order by created_timestamp, order_id) 
            as customer_order_seq_number
    from (select order_id, customer_id, source_relation, created_timestamp from joined where is_canceled = FALSE)
    --rank only orders that arent canceled

), windows_join as (
    select 
        joined.*, 
        coalesce(windows.customer_order_seq_number, 0) as customer_order_seq_number
    from joined
    left join windows using (order_id)

), new_vs_repeat as (

    select 
        *,
        case 
            when customer_order_seq_number = 0 then 'canceled'
            when customer_order_seq_number = 1 then 'new'
            else 'repeat'
        end as new_vs_repeat
    from windows_join

),
discount_application as (
    select *
    from {{ var('shopify_discount_application') }}
),
discount_application_agg as (
    select
        order_id,
        round(sum(case when (target_type = 'shipping_line' and value_type = 'fixed_amount') then value else 0 end), 2) as shipping_discount_fixed_amount,
        -- round(sum(case when (target_type = 'line_item' and value_type = 'fixed_amount') then discount_value else 0 end), 2) as line_item_discount_fixed_amount
    from discount_application
    group by 1

)

select *
from new_vs_repeat
left join discount_application_agg
using (order_id)