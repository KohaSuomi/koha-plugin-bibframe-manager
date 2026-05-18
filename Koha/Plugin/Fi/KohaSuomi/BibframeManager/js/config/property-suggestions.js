// Property suggestions for BFFI entities
// Based on bibframe_mapping.yaml and BFFI ontology

// API endpoint for fetching suggestions can be added later if needed, currently hardcoded in store

export const propertySuggestions = {
    work: [
        // Core relationships
        { label: 'hasExpression', value: 'bffi:hasExpression', type: 'relationship' },
        { label: 'hasRepresentativeExpression', value: 'bffi:hasRepresentativeExpression', type: 'relationship' },
        { label: 'hasPart', value: 'bffi:hasPart', type: 'relationship' },
        { label: 'partOf', value: 'bffi:partOf', type: 'relationship' },
        { label: 'relatedWork', value: 'bffi:relatedWork', type: 'relationship' },
        
        // Work-to-Work relationships
        { label: 'derivativeOf', value: 'bffi:derivativeOf', type: 'relationship' },
        { label: 'hasDerivative', value: 'bffi:hasDerivative', type: 'relationship' },
        { label: 'supplementTo', value: 'bffi:supplementTo', type: 'relationship' },
        { label: 'hasSupplement', value: 'bffi:hasSupplement', type: 'relationship' },
        { label: 'accompanimentTo', value: 'bffi:accompanimentTo', type: 'relationship' },
        { label: 'hasAccompaniment', value: 'bffi:hasAccompaniment', type: 'relationship' },
        { label: 'precededBy', value: 'bffi:precededBy', type: 'relationship' },
        { label: 'succeededBy', value: 'bffi:succeededBy', type: 'relationship' },
        { label: 'mergerOf', value: 'bffi:mergerOf', type: 'relationship' },
        { label: 'splitInto', value: 'bffi:splitInto', type: 'relationship' },
        { label: 'absorbedBy', value: 'bffi:absorbedBy', type: 'relationship' },
        { label: 'absorbed', value: 'bffi:absorbed', type: 'relationship' },
        { label: 'separatedFrom', value: 'bffi:separatedFrom', type: 'relationship' },
        
        // Creator and contribution
        { label: 'creator', value: 'bffi:creator', type: 'relationship' },
        { label: 'contributor', value: 'bffi:contributor', type: 'relationship' },
        { label: 'contribution', value: 'bffi:contribution', type: 'relationship' },
        
        // Title and identification
        { label: 'title', value: 'bffi:title', type: 'property' },
        { label: 'preferredTitle', value: 'bffi:preferredTitle', type: 'property' },
        
        // Classification and subjects
        { label: 'classification', value: 'bffi:classification', type: 'property' },
        { label: 'classificationPortion', value: 'bffi:classificationPortion', type: 'property' },
        { label: 'itemPortion', value: 'bffi:itemPortion', type: 'property' },
        { label: 'subject', value: 'bffi:subject', type: 'relationship' },
        { label: 'genreForm', value: 'bffi:genreForm', type: 'relationship' },
        
        // Work characteristics
        { label: 'formOfWork', value: 'bffi:formOfWork', type: 'property' },
        { label: 'intendedAudienceOfRepresentativeExpression', value: 'bffi:intendedAudienceOfRepresentativeExpression', type: 'relationship' },
        { label: 'creatorCharacteristic', value: 'bffi:creatorCharacteristic', type: 'relationship' },
        
        // Music-specific
        { label: 'musicKey', value: 'bffi:musicKey', type: 'property' },
        { label: 'musicMedium', value: 'bffi:musicMedium', type: 'relationship' },
        { label: 'numericDesignation', value: 'bffi:numericDesignation', type: 'property' },
        
        // Other characteristics
        { label: 'otherCharacteristics', value: 'bffi:otherCharacteristics', type: 'property' },
        { label: 'temporalCoverage', value: 'bffi:temporalCoverage', type: 'relationship' },
        { label: 'geographicCoverage', value: 'bffi:geographicCoverage', type: 'relationship' },
        { label: 'place', value: 'bffi:place', type: 'relationship' },
        
        // Content description
        { label: 'summary', value: 'bffi:summary', type: 'relationship' },
        { label: 'tableOfContents', value: 'bffi:tableOfContents', type: 'relationship' },
        { label: 'note', value: 'bffi:note', type: 'property' },
        
        // Dissertation
        { label: 'dissertation', value: 'bffi:dissertation', type: 'relationship' },
        
        // Awards
        { label: 'award', value: 'bffi:award', type: 'relationship' },
    ],
    
    expression: [
        // Core relationships
        { label: 'expressionOf', value: 'bffi:expressionOf', type: 'relationship' },
        { label: 'manifestationOfExpression', value: 'bffi:manifestationOfExpression', type: 'relationship' },
        { label: 'representativeExpressionOf', value: 'bffi:representativeExpressionOf', type: 'relationship' },
        
        // Expression relationships
        { label: 'relatedExpression', value: 'bffi:relatedExpression', type: 'relationship' },
        { label: 'partOfExpression', value: 'bffi:partOfExpression', type: 'relationship' },
        { label: 'hasPartExpression', value: 'bffi:hasPartExpression', type: 'relationship' },
        { label: 'translationOf', value: 'bffi:translationOf', type: 'relationship' },
        { label: 'hasTranslation', value: 'bffi:hasTranslation', type: 'relationship' },
        { label: 'revisionOf', value: 'bffi:revisionOf', type: 'relationship' },
        { label: 'hasRevision', value: 'bffi:hasRevision', type: 'relationship' },
        { label: 'abridgementOf', value: 'bffi:abridgementOf', type: 'relationship' },
        { label: 'hasAbridgement', value: 'bffi:hasAbridgement', type: 'relationship' },
        
        // Title
        { label: 'title', value: 'bffi:title', type: 'relationship' },
        { label: 'variantTitle', value: 'bffi:variantTitle', type: 'relationship' },
        { label: 'abbreviatedTitle', value: 'bffi:abbreviatedTitle', type: 'relationship' },
        { label: 'parallelTitle', value: 'bffi:parallelTitle', type: 'relationship' },
        
        // Language and content
        { label: 'language', value: 'bffi:language', type: 'relationship' },
        { label: 'languageOfExpression', value: 'bffi:languageOfExpression', type: 'relationship' },
        { label: 'languageNote', value: 'bffi:languageNote', type: 'property' },
        { label: 'content', value: 'bffi:content', type: 'relationship' },
        { label: 'contentType', value: 'bffi:contentType', type: 'property' },
        
        // Edition and version
        { label: 'edition', value: 'bffi:edition', type: 'property' },
        { label: 'editionStatement', value: 'bffi:editionStatement', type: 'property' },
        { label: 'responsibilityStatement', value: 'bffi:responsibilityStatement', type: 'property' },
        
        // Contribution
        { label: 'contributor', value: 'bffi:contributor', type: 'relationship' },
        { label: 'contribution', value: 'bffi:contribution', type: 'relationship' },
        
        // Date
        { label: 'date', value: 'bffi:date', type: 'property' },
        { label: 'originDate', value: 'bffi:originDate', type: 'property' },
        
        // Notation
        { label: 'notation', value: 'bffi:notation', type: 'relationship' },
        { label: 'musicNotation', value: 'bffi:musicNotation', type: 'relationship' },
        { label: 'movementNotation', value: 'bffi:movementNotation', type: 'relationship' },
        { label: 'script', value: 'bffi:script', type: 'relationship' },
        
        // Content description
        { label: 'summary', value: 'bffi:summary', type: 'relationship' },
        { label: 'tableOfContents', value: 'bffi:tableOfContents', type: 'relationship' },
        { label: 'note', value: 'bffi:note', type: 'property' },
        
        // Illustrative content
        { label: 'illustrativeContent', value: 'bffi:illustrativeContent', type: 'relationship' },
        { label: 'colorContent', value: 'bffi:colorContent', type: 'relationship' },
        { label: 'supplementaryContent', value: 'bffi:supplementaryContent', type: 'relationship' },
        
        // Series
        { label: 'series', value: 'bffi:series', type: 'relationship' },
        { label: 'seriesStatement', value: 'bffi:seriesStatement', type: 'property' },
        
        // Music specific
        { label: 'musicMedium', value: 'bffi:musicMedium', type: 'relationship' },
        { label: 'musicFormat', value: 'bffi:musicFormat', type: 'relationship' },
        
        // Related works
        { label: 'relatedWork', value: 'bffi:relatedWork', type: 'relationship' },
    ],
    
    manifestation: [
        // Core relationships
        { label: 'expressionManifested', value: 'bffi:expressionManifested', type: 'relationship' },
        { label: 'workManifested', value: 'bffi:workManifested', type: 'relationship' },
        { label: 'hasItem', value: 'bffi:hasItem', type: 'relationship' },
        
        // Manifestation relationships
        { label: 'relatedManifestation', value: 'bffi:relatedManifestation', type: 'relationship' },
        { label: 'reproduction', value: 'bffi:reproduction', type: 'relationship' },
        { label: 'reproductionOf', value: 'bffi:reproductionOf', type: 'relationship' },
        { label: 'electronicReproduction', value: 'bffi:electronicReproduction', type: 'relationship' },
        { label: 'hasPart', value: 'bffi:hasPart', type: 'relationship' },
        { label: 'partOf', value: 'bffi:partOf', type: 'relationship' },
        
        // Identifiers
        { label: 'identifiedBy', value: 'bffi:identifiedBy', type: 'relationship' },
        { label: 'isbn', value: 'bffi:isbn', type: 'property' },
        { label: 'issn', value: 'bffi:issn', type: 'property' },
        { label: 'urn', value: 'bffi:urn', type: 'property' },
        { label: 'doi', value: 'bffi:doi', type: 'property' },
        { label: 'fingerprint', value: 'bffi:fingerprint', type: 'property' },
        
        // Title
        { label: 'title', value: 'bffi:title', type: 'relationship' },
        { label: 'variantTitle', value: 'bffi:variantTitle', type: 'relationship' },
        { label: 'keyTitle', value: 'bffi:keyTitle', type: 'relationship' },
        
        // Publication and provision
        { label: 'publication', value: 'bffi:publication', type: 'relationship' },
        { label: 'provisionActivity', value: 'bffi:provisionActivity', type: 'relationship' },
        { label: 'production', value: 'bffi:production', type: 'relationship' },
        { label: 'distribution', value: 'bffi:distribution', type: 'relationship' },
        { label: 'manufacture', value: 'bffi:manufacture', type: 'relationship' },
        { label: 'copyright', value: 'bffi:copyright', type: 'relationship' },
        { label: 'copyrightRegistration', value: 'bffi:copyrightRegistration', type: 'relationship' },
        
        // Physical description
        { label: 'extent', value: 'bffi:extent', type: 'property' },
        { label: 'dimensions', value: 'bffi:dimensions', type: 'property' },
        
        // Media and carrier
        { label: 'media', value: 'bffi:media', type: 'relationship' },
        { label: 'mediaType', value: 'bffi:mediaType', type: 'property' },
        { label: 'carrier', value: 'bffi:carrier', type: 'relationship' },
        { label: 'carrierType', value: 'bffi:carrierType', type: 'property' },
        
        // Material characteristics
        { label: 'baseMaterial', value: 'bffi:baseMaterial', type: 'relationship' },
        { label: 'appliedMaterial', value: 'bffi:appliedMaterial', type: 'relationship' },
        { label: 'mount', value: 'bffi:mount', type: 'relationship' },
        { label: 'productionMethod', value: 'bffi:productionMethod', type: 'relationship' },
        { label: 'generation', value: 'bffi:generation', type: 'relationship' },
        { label: 'layout', value: 'bffi:layout', type: 'relationship' },
        { label: 'bookFormat', value: 'bffi:bookFormat', type: 'relationship' },
        { label: 'fontSize', value: 'bffi:fontSize', type: 'relationship' },
        { label: 'polarity', value: 'bffi:polarity', type: 'relationship' },
        
        // Sound characteristics
        { label: 'soundCharacteristic', value: 'bffi:soundCharacteristic', type: 'relationship' },
        { label: 'playbackChannels', value: 'bffi:playbackChannels', type: 'relationship' },
        { label: 'recordingMethod', value: 'bffi:recordingMethod', type: 'relationship' },
        
        // Video characteristics
        { label: 'videoCharacteristic', value: 'bffi:videoCharacteristic', type: 'relationship' },
        { label: 'broadcastStandard', value: 'bffi:broadcastStandard', type: 'relationship' },
        { label: 'videoFormat', value: 'bffi:videoFormat', type: 'relationship' },
        { label: 'color', value: 'bffi:color', type: 'relationship' },
        { label: 'aspectRatio', value: 'bffi:aspectRatio', type: 'relationship' },
        { label: 'soundContent', value: 'bffi:soundContent', type: 'relationship' },
        
        // Digital characteristics
        { label: 'digitalFileCharacteristic', value: 'bffi:digitalFileCharacteristic', type: 'relationship' },
        { label: 'encodingFormat', value: 'bffi:encodingFormat', type: 'relationship' },
        { label: 'fileType', value: 'bffi:fileType', type: 'relationship' },
        { label: 'fileSize', value: 'bffi:fileSize', type: 'relationship' },
        
        // Electronic location
        { label: 'electronicLocation', value: 'bffi:electronicLocation', type: 'property' },
        
        // Series
        { label: 'series', value: 'bffi:series', type: 'relationship' },
        { label: 'seriesStatement', value: 'bffi:seriesStatement', type: 'property' },
        { label: 'seriesEnumeration', value: 'bffi:seriesEnumeration', type: 'property' },
        
        // Issuance
        { label: 'issuance', value: 'bffi:issuance', type: 'relationship' },
        { label: 'frequency', value: 'bffi:frequency', type: 'relationship' },
        
        // Notes
        { label: 'note', value: 'bffi:note', type: 'property' },
    ],
    
    item: [
        // Core relationships
        { label: 'itemOf', value: 'bffi:itemOf', type: 'relationship' },
        
        // Holdings
        { label: 'heldBy', value: 'bffi:heldBy', type: 'relationship' },
        { label: 'shelfMark', value: 'bffi:shelfMark', type: 'relationship' },
        { label: 'sublocation', value: 'bffi:sublocation', type: 'relationship' },
        { label: 'enumerationAndChronology', value: 'bffi:enumerationAndChronology', type: 'relationship' },
        { label: 'enumeration', value: 'bffi:enumeration', type: 'relationship' },
        { label: 'chronology', value: 'bffi:chronology', type: 'relationship' },
        
        // Item information
        { label: 'itemInformation', value: 'bffi:itemInformation', type: 'property' },
        { label: 'barcode', value: 'bffi:barcode', type: 'property' },
        { label: 'copyNumber', value: 'bffi:copyNumber', type: 'property' },
        { label: 'pieceDesignation', value: 'bffi:pieceDesignation', type: 'property' },
        
        // Location
        { label: 'location', value: 'bffi:location', type: 'property' },
        { label: 'shelfLocation', value: 'bffi:shelfLocation', type: 'property' },
        { label: 'temporaryLocation', value: 'bffi:temporaryLocation', type: 'property' },
        
        // Access
        { label: 'usageAndAccessPolicy', value: 'bffi:usageAndAccessPolicy', type: 'relationship' },
        { label: 'immediateAcquisition', value: 'bffi:immediateAcquisition', type: 'relationship' },
        
        // Notes
        { label: 'note', value: 'bffi:note', type: 'property' },
        { label: 'itemSpecificNote', value: 'bffi:itemSpecificNote', type: 'property' },
    ]
};

// Relationship predicates from YAML
export const relationships = {
    // Work <-> Expression
    hasExpression: 'bffi:hasExpression',
    expressionOf: 'bffi:expressionOf',
    hasRepresentativeExpression: 'bffi:hasRepresentativeExpression',
    representativeExpressionOf: 'bffi:representativeExpressionOf',
    
    // Expression <-> Manifestation
    manifestationOfExpression: 'bffi:manifestationOfExpression',
    expressionManifested: 'bffi:expressionManifested',
    
    // Work <-> Manifestation
    manifestationOfWork: 'bffi:manifestationOfWork',
    workManifested: 'bffi:workManifested',
    
    // Manifestation <-> Item
    itemOf: 'bffi:itemOf',
    hasItem: 'bffi:hasItem',
    
    // Work <-> Work
    partOf: 'bffi:partOf',
    hasPart: 'bffi:hasPart',
    relatedWork: 'bffi:relatedWork',
    derivativeOf: 'bffi:derivativeOf',
    hasDerivative: 'bffi:hasDerivative',
    supplementTo: 'bffi:supplementTo',
    hasSupplement: 'bffi:hasSupplement',
    accompanimentTo: 'bffi:accompanimentTo',
    hasAccompaniment: 'bffi:hasAccompaniment',
    precededBy: 'bffi:precededBy',
    succeededBy: 'bffi:succeededBy',
    mergerOf: 'bffi:mergerOf',
    splitInto: 'bffi:splitInto',
    absorbedBy: 'bffi:absorbedBy',
    absorbed: 'bffi:absorbed',
    separatedFrom: 'bffi:separatedFrom',
    
    // Expression <-> Expression
    relatedExpression: 'bffi:relatedExpression',
    partOfExpression: 'bffi:partOfExpression',
    hasPartExpression: 'bffi:hasPartExpression',
    translationOf: 'bffi:translationOf',
    hasTranslation: 'bffi:hasTranslation',
    revisionOf: 'bffi:revisionOf',
    hasRevision: 'bffi:hasRevision',
    abridgementOf: 'bffi:abridgementOf',
    hasAbridgement: 'bffi:hasAbridgement',
    
    // Manifestation <-> Manifestation
    relatedManifestation: 'bffi:relatedManifestation',
    reproduction: 'bffi:reproduction',
    reproductionOf: 'bffi:reproductionOf',
    electronicReproduction: 'bffi:electronicReproduction',
    
    // Agent relationships
    contributor: 'bffi:contributor',
    creator: 'bffi:creator',
    contribution: 'bffi:contribution'
};

// RDF namespaces from YAML
export const namespaces = {
    bffi: 'http://urn.fi/URN:NBN:fi:schema:bffi:',
    'bffi-meta': 'http://urn.fi/URN:NBN:fi:schema:bffi-meta:',
    bf: 'http://id.loc.gov/ontologies/bibframe/',
    bflc: 'http://id.loc.gov/ontologies/bflc/',
    rdfs: 'http://www.w3.org/2000/01/rdf-schema#',
    rdf: 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
    rdaw: 'http://rdaregistry.info/Elements/w/',
    rdae: 'http://rdaregistry.info/Elements/e/',
    rdam: 'http://rdaregistry.info/Elements/m/',
    rdai: 'http://rdaregistry.info/Elements/i/',
    rdac: 'http://rdaregistry.info/Elements/c/',
    rdaa: 'http://rdaregistry.info/Elements/a/',
    rdap: 'http://rdaregistry.info/Elements/p/',
    dct: 'http://purl.org/dc/terms/',
    skos: 'http://www.w3.org/2004/02/skos/core#',
    owl: 'http://www.w3.org/2002/07/owl#',
    xsd: 'http://www.w3.org/2001/XMLSchema#'
};
